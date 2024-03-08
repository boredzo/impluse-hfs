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

#import "ImpSourceVolume.h"
#import "ImpDestinationVolume.h"

#import <sys/stat.h>

@interface ImpVolumeProbe ()

@property(readwrite) NSError *_Nullable error;

///Attempts to determine the size of the whole device/file. May return 0 if fstat was no help.
- (u_int64_t) sizeInBytesAccordingToStat;
- (void) scan;

@end

@interface APMPartition : NSObject

+ (instancetype _Nonnull) partitionWithFirstBlockNumber:(u_int32_t const)startBlock numberOfBlocks:(u_int32_t const)numBlocks;

///The 0-based number of the block where this partition starts. The partition map partition always starts at block 1 (immediately following the driver descriptor block at block 0).
@property(readonly) u_int32_t firstBlockNumber;
///The length of the partition in 0x200-byte blocks.
@property(readonly) u_int32_t numberOfBlocks;

///The start block times 0x200 bytes.
@property(readonly) u_int64_t offsetIntoPartitionSchemeInBytes;

@end

///IM:D calls this structure “Block0”. All fields are big-endian.
///We don't really care about trying to parse the driver descriptor block, other than checking the signature. If we find the driver descriptor block, we can expect it to be followed immediately by the partition map.
///(Note that absence of a DDB does not imply absence of an APM. There can be a PM block with no preceding ER block.)
enum {
	APMDriverDescriptorBlockSignature = 0x4552, //'ER'
	APMDriverDescriptorBlockSignatureAlternate = 0x0000, //Sometimes there's no Driver Descriptor Record but block 0 is still followed by one or more partition map entries.

	//IM:D: “This field should contain the value of the pMapSIG constant ($504D). An earlier but still supported version uses the value $5453.”
	APMPartitionMapIM5EntrySignature = 0x504D, //'PM'
	APMPartitionMapIM4EntrySignature = 0x5453, //'TS'
	APMPartitionMapNullSignature = 0x0,
};
typedef u_int16_t APMBlockSignature;
struct APMDriverDescriptorBlock {
	APMBlockSignature signature; //'ER'
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
} __attribute__((aligned(2), packed));

struct APMPartitionRecord_IM4 {
	u_int32_t thisPartitionStartBlock;
	u_int32_t thisPartitionBlockCount;
	OSType partitionType;
} __attribute__((aligned(2), packed));
enum {
	APMPartitionMap_IM4_MaxPartitionsPerBlock = kISOStandardBlockSize / sizeof(struct APMPartitionRecord_IM4),
	APMPartitionMap_IM4_PartitionTypeHFS = 'TFS1', //TFS = Turbo File System, an early name for what would later be officially named HFS
};
struct APMPartitionMap_IM4 {
	APMBlockSignature signature; //'PM'
	struct APMPartitionRecord_IM4 partitions[APMPartitionMap_IM4_MaxPartitionsPerBlock];
} __attribute__((aligned(2), packed));

struct APMPartitionRecord_IM5 {
	APMBlockSignature signature; //'PM'
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
} __attribute__((aligned(2), packed));

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

///Returns whether this storage appears to contain an Apple Partition Map. Even if the storage contains no interesting volumes (e.g., only Apple_Free or only ProDOS or something), finding an APM is success.
- (bool) scanApplePartitionMap {
	NSUInteger firstPMBlock = 0;
	NSData *_Nonnull const firstBlock = [self readOneISOStandardBlockAtIndex:0];
	struct APMDriverDescriptorBlock const *_Nonnull const maybeDDB = (void const *)(firstBlock.bytes);
	switch (L(maybeDDB->signature)) {
		case APMDriverDescriptorBlockSignature:
			//It's a DDB. We should definitely have an APM, just after the DDB.
			if (self.verbose) ImpPrintf(@"Found an Apple Partition Map Driver Descriptor Block");
		case APMDriverDescriptorBlockSignatureAlternate:
			//If the space where the DDB should be is empty, the partition map might start in the second block. (It certainly isn't in the *first* block, anyway.)
			if (self.verbose) ImpPrintf(@"Space where Driver Descriptor Block might've been is empty; could still be an Apple Partition Map");
			firstPMBlock = 1;
			break;

		default:
			//Whatever this is, it doesn't look like a DDB. Reject it.
			if (self.verbose) ImpPrintf(@"Definitely not an Apple Partition Map");
			return false;
	}

	NSData *_Nullable partitionMapEntryData = [self readOneISOStandardBlockAtIndex:firstPMBlock];
	if (partitionMapEntryData != nil) {
		void const *_Nonnull const partitionMapEntryBytes = partitionMapEntryData.bytes;
		APMBlockSignature const * _Nonnull const signaturePtr = partitionMapEntryBytes;
		switch (L(*signaturePtr)) {
			case APMPartitionMapIM5EntrySignature:
				if (self.verbose) ImpPrintf(@"Found an IM5 Apple Partition Map entry");
				struct APMPartitionRecord_IM5 const *_Nullable partition5 = partitionMapEntryBytes;
				return [self scanIM5PartitionMap:partition5 firstPartitionMapBlock:firstPMBlock];
				break;
			case APMPartitionMapIM4EntrySignature:
				if (self.verbose) ImpPrintf(@"Found an IM4 Apple Partition Map");
				struct APMPartitionMap_IM4 const *_Nullable partition4 = partitionMapEntryBytes;
				return [self scanIM4PartitionMap:partition4 firstPartitionMapBlock:firstPMBlock];
				break;
			default:
				//Signature mismatch—this is not an APM entry. And since it's supposed to be first APM entry, that means there's no APM.
				if (self.verbose) ImpPrintf(@"Space where partition map entry should be is not an Apple Partition Map entry");
				break;
		}
	}

	return false;
}

- (bool) scanIM5PartitionMap:(struct APMPartitionRecord_IM5 const *_Nonnull const)firstPartitionBlock firstPartitionMapBlock:(NSUInteger const)firstPMBlockNum {
	bool foundAnyPartitions = false;

	//HAZARD: If the first partition map block has an incorrect number of map blocks, this could go wrong. Might need to take a majority vote of non-zero counts from other PMBs?
	NSUInteger const numPartitions = L(firstPartitionBlock->numMapBlocks);
	for (u_int32_t partitionIndex = 0; partitionIndex < numPartitions; ++partitionIndex) {
		NSData *_Nullable partitionMapEntryData = [self readOneISOStandardBlockAtIndex:firstPMBlockNum + partitionIndex];
		if (partitionMapEntryData != nil) {
			void const *_Nonnull const partitionMapEntryBytes = partitionMapEntryData.bytes;
			APMBlockSignature const * _Nonnull const signaturePtr = partitionMapEntryBytes;
			struct APMPartitionRecord_IM5 const *_Nullable thisPartition = NULL;

			APMBlockSignature foundMapSignature = L(*signaturePtr);
			switch (foundMapSignature) {
				case APMPartitionMapIM5EntrySignature:
					if (self.verbose) ImpPrintf(@"Found an IM5 Apple Partition Map entry");
					thisPartition = partitionMapEntryBytes;
					break;
				case APMPartitionMapIM4EntrySignature:
					if (self.verbose) ImpPrintf(@"Found an IM4 Apple Partition Map inside an IM5 Apple Partition Map????");
					break;
				default:
					//Signature mismatch—this is not an APM entry. And since it's supposed to be first APM entry, that means there's no APM.
					if (self.verbose) ImpPrintf(@"Space where partition map entry should be is not an Apple Partition Map entry");
					break;
			}
			if (foundMapSignature != APMPartitionMapIM5EntrySignature) {
				continue;
			}

			if (self.verbose) ImpPrintf(@"Entry #%u partition type is %s", partitionIndex, thisPartition->partitionType);
			if (strcmp(thisPartition->partitionType, "Apple_HFS") == 0) {
				u_int32_t const hfsBootBlocksStartBlockIndex = L(thisPartition->thisPartitionStartBlock);
				if (self.verbose) ImpPrintf(@"Entry #%u describes an HFS volume. First physical block (location of boot blocks) is #%u", partitionIndex, hfsBootBlocksStartBlockIndex);
				u_int32_t const hfsVolumeHeaderBlockIndex = hfsBootBlocksStartBlockIndex + 2;
				NSData *_Nonnull const thirdVolumeBlockData = [self readOneISOStandardBlockAtIndex:hfsVolumeHeaderBlockIndex];

				Class _Nullable identifiedClass = Nil;

				struct HFSMasterDirectoryBlock const *_Nonnull const mdbPtr = (struct HFSMasterDirectoryBlock const *_Nonnull)thirdVolumeBlockData.bytes;
				if (L(mdbPtr->drSigWord) == kHFSSigWord) {
					if (self.verbose) ImpPrintf(@"Volume is an HFS volume");
					identifiedClass = [ImpSourceVolume class];
				} else {
					struct HFSPlusVolumeHeader const *_Nonnull const vhPtr = (struct HFSPlusVolumeHeader const *_Nonnull)thirdVolumeBlockData.bytes;
					if (L(vhPtr->signature) == kHFSPlusSigWord) {
						if (self.verbose) ImpPrintf(@"Volume is an HFS+ volume");
						identifiedClass = [ImpDestinationVolume class];
					} else {
						//Signature isn't HFS or HFS+? This may be mapped as an Apple_HFS partition, but it's not a usable HFS or HFS+ volume. Skip it.
						if (self.verbose) ImpPrintf(@"Volume is not an HFS or HFS+ volume");
						continue;
					}
				}

				foundAnyPartitions = true;

				u_int32_t const hfsVolumeBlockCount = L(thisPartition->thisPartitionBlockCount);
				[self foundVolumeStartingAtBlock:hfsBootBlocksStartBlockIndex blockCount:hfsVolumeBlockCount class:identifiedClass];
			}
		}
	}

	return foundAnyPartitions;
}

- (bool) scanIM4PartitionMap:(struct APMPartitionMap_IM4 const *_Nonnull const)firstPartitionBlock firstPartitionMapBlock:(NSUInteger const)firstPMBlockNum {
	bool haveFoundAnyPartitions = false;

	for (u_int32_t partitionIndex = 0; partitionIndex < APMPartitionMap_IM4_MaxPartitionsPerBlock; ++partitionIndex) {
		struct APMPartitionRecord_IM4 const *_Nonnull const thisPartition = &firstPartitionBlock->partitions[partitionIndex];
		if (thisPartition->thisPartitionStartBlock == 0 || thisPartition->thisPartitionBlockCount == 0 || thisPartition->partitionType == 0) {
			//We have scanned all partitions.
			break;
		} else {
			OSType const partitionType = L(thisPartition->partitionType);
			if (partitionType == APMPartitionMap_IM4_PartitionTypeHFS) {
				u_int32_t const hfsBootBlocksStartBlockIndex = L(thisPartition->thisPartitionStartBlock);
				if (self.verbose) ImpPrintf(@"Entry #%u describes an HFS volume. First physical block (location of boot blocks) is #%u", partitionIndex, hfsBootBlocksStartBlockIndex);
				u_int32_t const hfsVolumeHeaderBlockIndex = hfsBootBlocksStartBlockIndex + 2;
				NSData *_Nonnull const thirdVolumeBlockData = [self readOneISOStandardBlockAtIndex:hfsVolumeHeaderBlockIndex];

				Class _Nullable identifiedClass = Nil;

				struct HFSMasterDirectoryBlock const *_Nonnull const mdbPtr = (struct HFSMasterDirectoryBlock const *_Nonnull)thirdVolumeBlockData.bytes;
				if (L(mdbPtr->drSigWord) == kHFSSigWord) {
					if (self.verbose) ImpPrintf(@"Volume is an HFS volume");
					identifiedClass = [ImpSourceVolume class];
				} else {
					struct HFSPlusVolumeHeader const *_Nonnull const vhPtr = (struct HFSPlusVolumeHeader const *_Nonnull)thirdVolumeBlockData.bytes;
					if (L(vhPtr->signature) == kHFSPlusSigWord) {
						if (self.verbose) ImpPrintf(@"Volume is an HFS+ volume");
						identifiedClass = [ImpDestinationVolume class];
					} else {
						//Signature isn't HFS or HFS+? This may be mapped as an Apple_HFS partition, but it's not a usable HFS or HFS+ volume. Skip it.
						if (self.verbose) ImpPrintf(@"Volume is not an HFS or HFS+ volume");
						continue;
					}
				}

				haveFoundAnyPartitions = true;

				u_int32_t const hfsVolumeBlockCount = L(thisPartition->thisPartitionBlockCount);
				[self foundVolumeStartingAtBlock:hfsBootBlocksStartBlockIndex blockCount:hfsVolumeBlockCount class:identifiedClass];
			}
		}
	}

	return haveFoundAnyPartitions;
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
			[self foundVolumeStartingAtBlock:startBlock blockCount:numBlocks class:[ImpSourceVolume class]];
			return true;
		} else if (signature == kHFSPlusSigWord) {
			[self foundVolumeStartingAtBlock:startBlock blockCount:numBlocks class:[ImpDestinationVolume class]];
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

@implementation APMPartition

+ (instancetype _Nonnull) partitionWithFirstBlockNumber:(u_int32_t const)startBlock numberOfBlocks:(u_int32_t const)numBlocks {
	return [[self alloc] initWithFirstBlockNumber:startBlock numberOfBlocks:numBlocks];
}
- (instancetype _Nonnull) initWithFirstBlockNumber:(u_int32_t const)startBlock numberOfBlocks:(u_int32_t const)numBlocks {
	if ((self = [super init])) {
		_firstBlockNumber = startBlock;
		_numberOfBlocks = numBlocks;
		_offsetIntoPartitionSchemeInBytes = _firstBlockNumber * kISOStandardBlockSize;
	}
	return self;
}

@end
