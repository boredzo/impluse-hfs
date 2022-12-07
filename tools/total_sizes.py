#!/usr/bin/python3

import fileinput

totdf = 0
totrf = 0
totboth = 0

for line in fileinput.input():
	name, dfsize, rfsize, bothsize = line.split('\t')
	dfsize = int(dfsize.replace(',', ''))
	rfsize = int(rfsize.replace(',', ''))
	bothsize = int(bothsize.replace(',', ''))
	totdf += dfsize
	totrf += rfsize
	totboth += bothsize

print('Total\t{:,}\t{:,}\t{:,}'.format(totdf, totrf, totboth))
