#!/usr/bin/env python3
"""Check literal/interpolated localization keys without executing Swift or user data."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def string(source, start):
    delimiter = '"""' if source.startswith('"""', start) else '"'
    cursor = start + len(delimiter)
    parts, expressions, literal = [], [], ''
    while cursor < len(source):
        if source.startswith(delimiter, cursor):
            parts.append(literal)
            end = cursor + len(delimiter)
            if len(delimiter) == 3:
                indent = source[source.rfind('\n', start, end) + 1:end - 3]
                parts = [part.replace('\n' + indent, '\n') for part in parts]
                parts[0] = parts[0].removeprefix('\n')
                parts[-1] = parts[-1].removesuffix('\n')
            key = ''.join(part + ('{' + str(index) + '}' if index < len(expressions) else '')
                          for index, part in enumerate(parts))
            return end, key, expressions
        if source.startswith('\\(', cursor):
            begin, depth = cursor + 2, 1
            cursor = begin
            while depth:
                if source[cursor] == '"':
                    cursor = string(source, cursor)[0]
                    continue
                if source[cursor] == '(':
                    depth += 1
                elif source[cursor] == ')':
                    depth -= 1
                cursor += 1
            expressions.append(source[begin:cursor - 1])
            parts.append(literal)
            literal = ''
        elif source[cursor] == '\\':
            escape = source[cursor:cursor + 2]
            literal += {'\\n': '\n', '\\t': '\t', '\\r': '\r', '\\"': '"', '\\\\': '\\'}.get(escape, escape)
            cursor += 2
        else:
            literal += source[cursor]
            cursor += 1
    raise ValueError('Unclosed Swift string')


def messages(source, stored=False):
    cursor = 0
    while cursor < len(source):
        if source.startswith('//', cursor):
            cursor = source.find('\n', cursor)
            if cursor < 0:
                break
        elif source.startswith('/*', cursor):
            cursor = source.index('*/', cursor + 2) + 2
        elif source[cursor] == '"':
            end, key, expressions = string(source, cursor)
            if re.search(r'\bL\(\s*$', source[:cursor]) or (stored and re.search(r'\b(?:message|statusMessage)(?:: HubLocalizedMessage)?\s*=\s*$', source[:cursor])):
                yield key
            # Nested interpolation may contain independent localized fallbacks.
            for expression in expressions:
                yield from messages(expression, stored=stored)
            cursor = end
        else:
            cursor += 1


catalog = {}
for line in (ROOT / 'Sources/LocalizationCatalog.swift').read_text().splitlines():
    if not line.strip().startswith('"'):
        continue
    decoder = json.JSONDecoder()
    key, offset = decoder.raw_decode(line.strip())
    value, _ = decoder.raw_decode(line.strip()[offset:].lstrip(': '))
    assert key not in catalog, f'Duplicate translation: {key}'
    assert sorted(re.findall(r'\{\d+\}', key)) == sorted(re.findall(r'\{\d+\}', value)), key
    catalog[key] = value

used = set()
for path in (ROOT / 'Sources').glob('*.swift'):
    if path.name == 'LocalizationCatalog.swift':
        continue
    for key in messages(path.read_text(), stored=path.name == "SoftwareUpdate.swift"):
        assert key in catalog, f'{path.name}: missing English translation: {key}'
        used.add(key)
print(f'PASS: {len(used)} source message templates, {len(catalog)} translations; no missing keys, duplicates, or argument mismatches')
