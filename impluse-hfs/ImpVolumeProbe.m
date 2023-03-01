//
//  ImpVolumeProbe.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2023-02-28.
//

#import "ImpVolumeProbe.h"

#import "ImpSizeUtilities.h"
#import "ImpByteOrder.h"
#import "NSData+ImpSubdata.h"

#import "ImpHFSVolume.h"
#import "ImpHFSPlusVolume.h"

#import <sys/stat.h>

@interface ImpVolumeProbe ()

@property(readwrite) NSError *_Nullable error;

///Attempts to determine the size of the whole device/file. May return 0 if fstat was no help.
- (u_int64_t) sizeInBytesAccordingToStat;
- (void) scan;

@end

@implementation ImpVolumeProbe
{
	int _readFD;
	NSMutableArray <NSValue *> *_Nonnull _volumeRanges;
	NSMutableArray *_Nonnull _volumeClasses; //Either Class or NSNull *
	bool _hasScanned;
}

- (instancetype _Nonnull) initWithFileDescriptor:(int const)readFD {
	if ((self = [super init])) {
		_readFD = readFD;
		_volumeRanges = [NSMutableArray new];
		_volumeClasses = [NSMutableArray new];
	}
	return self;
}

- (u_int64_t) sizeInBytesAccordingToStat {
	u_int64_t sizeInBytes = 0;
	struct stat sb;
	int const statResult = fstat(_readFD, &sb);
	if (statResult == 0) {
		off_t const sizeAccordingToStat = sb.st_size;
		if (sizeAccordingToStat > 0) {
			sizeInBytes = (u_int64_t)sizeAccordingToStat;
		}
	}
	return sizeInBytes;
}

- (NSData *_Nullable) readOneISOStandardBlockAtIndex:(NSUInteger const)idx {
	size_t const amtToRead = kISOStandardBlockSize;
	NSMutableData *_Nonnull const mutableData = [NSMutableData dataWithLength:amtToRead];
	void *_Nonnull const buf = mutableData.mutableBytes;

	ssize_t const amtRead = pread(_readFD, buf, amtToRead, kISOStandardBlockSize * idx);

	bool const readSuccessfully = (amtRead == amtToRead);
	if (! readSuccessfully) {
		self.error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedString(@"Read failure while probing volumes", @"Volume probe error") }];
	}

	return readSuccessfully ? mutableData : nil;
}

#pragma mark -

- (void) foundVolumeStartingAtBlock:(u_int64_t const)startBlock blockCount:(u_int64_t const)numBlocks class:(Class _Nullable const)volumeClass {
	NSRange const range = { startBlock, numBlocks };
	NSValue *_Nonnull const value = [NSValue valueWithRange:range];
	[_volumeRanges addObject:value];
	[_volumeClasses addObject:volumeClass != Nil ? (id)volumeClass : (id)[NSNull null]];
}

- (NSUInteger) numberOfInterestingVolumes {
	if (! _hasScanned) {
		[self scan];
	}
	return _volumeRanges.count;
}

- (void) findVolumes:(void (^_Nonnull const)(u_int64_t const startOffsetInBytes, u_int64_t const lengthInBytes, Class _Nullable const volumeClass))block {
	if (! _hasScanned) {
		[self scan];
	}

	NSUInteger i = 0;
	NSNull *_Nonnull const noVolumeClassOnFile = [NSNull null];
	for (NSValue *_Nonnull const rangeValue in _volumeRanges) {
		id _Nonnull const maybeVolumeClass = _volumeClasses[i];
		Class _Nullable const volumeClass = (maybeVolumeClass != noVolumeClassOnFile ? maybeVolumeClass : Nil);

		NSRange const rangeInBlocks = rangeValue.rangeValue;
		NSRange const rangeInBytes = {
			rangeInBlocks.location * kISOStandardBlockSize,
			rangeInBlocks.length * kISOStandardBlockSize,
		};

		block(rangeInBytes.location, rangeInBytes.length, volumeClass);
		++i;
	}
}

#pragma mark -

- (bool) scanApplePartitionMap {
	return false;
}
- (bool) scanBareVolumeStartingAtBlock:(u_int64_t const)startBlock blockCount:(u_int64_t const)numBlocks  {
	NSData *_Nonnull const thirdBlock = [self readOneISOStandardBlockAtIndex:startBlock + 2];
	if (thirdBlock != nil) {
		__block u_int16_t signature = 0;
		[thirdBlock withRange:(NSRange){ 0, kISOStandardBlockSize } showSubdataToBlock_Imp:^(const void * _Nonnull bytes, NSUInteger length) {
			u_int16_t const *_Nonnull const maybeSignaturePtr = (u_int16_t const *)bytes;
			signature = L(*maybeSignaturePtr);
		}];
		if (signature == kHFSSigWord) {
			[self foundVolumeStartingAtBlock:startBlock blockCount:numBlocks class:[ImpHFSVolume class]];
			return true;
		} else if (signature == kHFSPlusSigWord) {
			[self foundVolumeStartingAtBlock:startBlock blockCount:numBlocks class:[ImpHFSPlusVolume class]];
			return true;
		}
	}

	return false;
}

- (void) scan {
	[self scanApplePartitionMap] || [self scanBareVolumeStartingAtBlock:0 blockCount:self.sizeInBytesAccordingToStat / kISOStandardBlockSize];
	_hasScanned = true;
}

@end
