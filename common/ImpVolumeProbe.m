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

///IM:D calls this structure “Block0”. All fields are big-endian.
///We don't really care about trying to parse the driver descriptor block, other than checking the signature. If we find the driver descriptor block, we can expect it to be followed immediately by the partition map.
///(Note that absence of a DDB does not imply absence of an APM. There can be a PM block with no preceding ER block.)
enum {
	APMDriverDescriptorBlockSignature = 0x4552, //'ER'
	APMDriverDescriptorBlockSignatureAlternate = 0x0000, //Sometimes there's no Driver Descriptor Record but block 0 is still followed by one or more partition map entries.

	//IM:D: “This field should contain the value of the pMapSIG constant ($504D). An earlier but still supported version uses the value $5453.”
	APMPartitionMapEntrySignature = 0x504D, //'PM'
	APMPartitionMapEntrySignatureOldStyle = 0x5453, //'ST'
};
struct APMDriverDescriptorBlock {
	u_int16_t signature; //'ER'
	u_int16_t bytesPerBlock;
	u_int32_t numBlocks;
	u_int16_t devType; //reserved
	u_int16_t devID; //reserved
	u_int32_t data; //reserved
	u_int16_t numDrivers;
	struct APMDriverRecord {
		u_int32_t driverStartBlock;
		u_int16_t driverBlockCount;
		u_int16_t operatingSystemType; //Mac OS == 1
	} driverRecords[(0x200 - (2+2+4+2+2+4+2)) / 8];
	u_int32_t pad; //reserved
};
struct APMPartition {
	u_int16_t signature; //'PM'
	u_int16_t signaturePad;
	u_int32_t numMapBlocks;
	u_int32_t thisPartitionStartBlock;
	u_int32_t thisPartitionBlockCount;
	char partitionName[32]; //Not as useful as you might think. Often contradicted by the volume header, partly because naming it something starting with 'Maci' (like "Macintosh HD") triggers the boot code checksum verification.
	char partitionType[32]; //Much more useful. "Apple_HFS" is the type we're looking for.
	u_int32_t dataStartBlock; //Logical block—relative to thisPartitionStartBlock.
	u_int32_t dataBlockCount;
	u_int32_t status; //“currently used only by the A/UX operating system”
	u_int32_t bootStartBlock;
	u_int32_t bootCodeLengthInBytes;
	u_int32_t bootLoadAddress0;
	u_int32_t bootLoadAddress1; //reserved
	u_int32_t bootEntryPoint0;
	u_int32_t bootEntryPoint1; //reserved
	u_int32_t bootCodeChecksum;
	Str15 processorType;
	u_int16_t pad[188];
};

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
	enum {
		sbSIGWord = 0x4552, //'ER'
		pMapSIG = 0x504D, //'PM'
		pMapSIGOldStyle = 0x5453, //'TS'
	};

	NSUInteger firstPMBlock = 0;
	NSData *_Nonnull const firstBlock = [self readOneISOStandardBlockAtIndex:0];
	struct APMDriverDescriptorBlock const *_Nonnull const maybeDDB = (void const *)(firstBlock.bytes);
	switch (L(maybeDDB->signature)) {
		case APMDriverDescriptorBlockSignature:
			//It's a DDB. We should definitely have an APM, just after the DDB.
		case APMDriverDescriptorBlockSignatureAlternate:
			//If the space where the DDB should be is empty, the partition map might start in the second block. (It certainly isn't in the *first* block, anyway.)
			firstPMBlock = 1;
			break;

		default:
			//Whatever this is, it doesn't look like a DDB. Reject it.
			return false;
	}

	bool foundPartitionMap = false;

	NSUInteger partitionIndex = 0;
	NSUInteger numPartitions = 0;
	do {
		NSData *_Nullable partitionMapEntryData = [self readOneISOStandardBlockAtIndex:firstPMBlock + partitionIndex];
		if (partitionMapEntryData != nil) {
			struct APMPartition const *_Nonnull const partition = partitionMapEntryData.bytes;
			if (numPartitions == 0) {
				switch (L(partition->signature)) {
					case APMPartitionMapEntrySignature:
					case APMPartitionMapEntrySignatureOldStyle:
						foundPartitionMap = true;
						break;
					default:
						//Signature mismatch—this is not an APM entry. And since it's supposed to be first APM entry, that means there's no APM.
						foundPartitionMap = false;
						break;
				}
				if (! foundPartitionMap) {
					break;
				}

				numPartitions = L(partition->numMapBlocks);
			}

			if (strcmp(partition->partitionType, "Apple_HFS") == 0) {
				u_int32_t const hfsBootBlocksStartBlockIndex = L(partition->thisPartitionStartBlock);
				u_int32_t const hfsVolumeHeaderBlockIndex = hfsBootBlocksStartBlockIndex + 2;
				NSData *_Nonnull const thirdVolumeBlockData = [self readOneISOStandardBlockAtIndex:hfsVolumeHeaderBlockIndex];

				Class _Nullable identifiedClass = Nil;

				struct HFSMasterDirectoryBlock const *_Nonnull const mdbPtr = (struct HFSMasterDirectoryBlock const *_Nonnull)thirdVolumeBlockData.bytes;
				if (L(mdbPtr->drSigWord) == kHFSSigWord) {
					identifiedClass = [ImpHFSVolume class];
				} else {
					struct HFSPlusVolumeHeader const *_Nonnull const vhPtr = (struct HFSPlusVolumeHeader const *_Nonnull)thirdVolumeBlockData.bytes;
					if (L(vhPtr->signature) == kHFSPlusSigWord) {
						identifiedClass = [ImpHFSPlusVolume class];
					} else {
						//Signature isn't HFS or HFS+? This may be mapped as an Apple_HFS partition, but it's not a usable HFS or HFS+ volume. Skip it.
						continue;
					}
				}

				u_int32_t const hfsVolumeBlockCount = L(partition->thisPartitionBlockCount);
				[self foundVolumeStartingAtBlock:hfsBootBlocksStartBlockIndex blockCount:hfsVolumeBlockCount class:identifiedClass];
			}
		}
	} while (partitionIndex++ < numPartitions);

	return foundPartitionMap;
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
