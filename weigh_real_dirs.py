#!/usr/bin/python3

import os
import pathlib
import argparse

parser = argparse.ArgumentParser()
parser.add_argument('root_path', type=pathlib.Path)
opts = parser.parse_args()

print('''Name   	Data size	Rsrc size	Total size
═══════	═════════	═════════	═════════''')

df_total = 0
rf_total = 0
both_total = 0

root_path: pathlib.Path = opts.root_path
for dir_path, dir_names, file_names in os.walk(root_path):
	dir_path = pathlib.Path(dir_path)
	subpath = dir_path.relative_to(root_path)
	depth = len(subpath.parts)

	# Note: Must be done to the original dir_names as it affects visitation order.
	for name in list(dir_names):
		if name.startswith('.'):
			dir_names.remove(name)
	dir_names.sort(key=str.lower)

	file_names = [name for name in file_names if not name.startswith('.')]
	child_names = dir_names + file_names
	child_names.sort(key=str.lower)

	print('{}{} {} contains {} items'.format(' ' * depth, '📁' if depth > 0 else '🗄', dir_path.name, len(child_names)))

	depth += 1
	for name in child_names:
		if name in dir_names:
			subdir_path = dir_path.joinpath(name)
			children = list(subdir_path.glob('*'))
			print('{}{} {} contains {} items'.format(' ' * depth, '📁', subdir_path.name.replace(':', '/'), len(children)))
		elif name in file_names:
			df_path = dir_path.joinpath(name)
			rf_path = df_path.joinpath('..namedfork/rsrc')
			df_size = df_path.lstat().st_size
			try:
				rf_size = rf_path.lstat().st_size
			except FileNotFoundError:
				rf_size = 0
			both_size = df_size + rf_size

			df_total += df_size
			rf_total += rf_size
			both_total += both_size

			print('{}{} {}\t{:,}\t{:,}\t{:,}'.format(' ' * depth, '📄', name.replace(':', '/'), df_size, rf_size, both_size))
	print()

print('═══════	═════════	═════════	═════════')
print('Total\t{:,}\t{:,}\t{:,}'.format(df_total, rf_total, both_total))
