//
//  ImpDestinationVolume.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-26.
//

#import "ImpDestinationVolume.h"

#import "NSData+ImpSubdata.h"
#import "ImpByteOrder.h"
#import "ImpPrintf.h"
#import "ImpSizeUtilities.h"

#import <sys/stat.h>
#import <hfs/hfs_format.h>

//For implementing the read side
#import "ImpTextEncodingConverter.h"
#import "ImpBTreeFile.h"

#import "ImpVirtualFileHandle.h"

@interface ImpDestinationVolume ()

- (u_int32_t) numBlocksForPreambleWithSize:(u_int32_t const)aBlockSize;
- (u_int32_t) numBlocksForPostambleWithSize:(u_int32_t const)aBlockSize;

///Low-level method. Marks the blocks within the extent as allocated.
///WARNING: This method does not check that these blocks are available/not already allocated. It is meant for implementing higher-level allocation methods, such as those declared in the header, that do perform such checks. You probably want one of those.
- (void) allocateBlocksOfExtent:(const struct HFSPlusExtentDescriptor *_Nonnull const)oneExtent;

///Low-level method. Marks the blocks within the extent as unallocated (available).
///You should not use this extent afterward, or write to any blocks newly freed.
///WARNING: This method does not check that these blocks are allocated, nor does it make sure nothing is using these blocks. It is meant for implementing higher-level allocation and deallocation methods, such as those declared in the header, that do perform such checks. You probably want one of those.
- (void) deallocateBlocksOfExtent:(const struct HFSPlusExtentDescriptor *_Nonnull const)oneExtent;

@end

@implementation ImpDestinationVolume

- (void) impluseBugDetected_messageSentToAbstractClass {
	NSAssert(false, @"Message %s sent to instance of class %@, which hasn't implemented it (instance of abstract class, method not overridden, or super called when it shouldn't have been)", sel_getName(_cmd), [self class]);
}

- (instancetype _Nonnull)initForWritingToFileDescriptor:(int)writeFD
	startAtOffset:(u_int64_t)startOffsetInBytes
	expectedLengthInBytes:(u_int64_t)lengthInBytes
{
	if ((self = [super init])) {
		_fileDescriptor = writeFD;

		_startOffsetInBytes = startOffsetInBytes;
		_lengthInBytes = lengthInBytes;

		self.textEncodingConverter = [[ImpTextEncodingConverter alloc] initWithHFSTextEncoding:kTextEncodingMacRoman];
	}
	return self;
}

- (bool) flushVolumeStructures:(NSError *_Nullable *_Nullable const)outError {
	[self impluseBugDetected_messageSentToAbstractClass];
	return false;
}

+ (u_int32_t) optimalAllocationBlockSizeForVolumeLength:(u_int64_t)numBytes {
	u_int32_t naiveBlockSize = (u_int32_t)(numBytes / UINT32_MAX);
	if (naiveBlockSize % kISOStandardBlockSize != 0) {
		naiveBlockSize += kISOStandardBlockSize - (naiveBlockSize % kISOStandardBlockSize);
	}

	u_int32_t validBlockSize;
	for (validBlockSize = kISOStandardBlockSize; validBlockSize < naiveBlockSize; validBlockSize *= 2);

	return validBlockSize;
}

///Note that this may return a number larger than can fit in a u_int32_t, and thus larger than can be stored in a single extent. If the return value is greater than UINT_MAX, you should allocate multiple extents as needed to whittle it down to fit.
- (u_int64_t) countOfBlocksOfSize:(u_int32_t const)blockSize neededForLogicalLength:(u_int64_t const)length {
	u_int64_t const numBlocks = ImpCeilingDivide(length, blockSize);

	return numBlocks;
}

#pragma mark Writing data

- (ImpVirtualFileHandle *_Nonnull const) fileHandleForWritingToExtents:(struct HFSPlusExtentDescriptor const *_Nonnull const)extentRecPtr {
	return [[ImpVirtualFileHandle alloc] initWithVolume:self extents:extentRecPtr];
}

- (int64_t)writeData:(NSData *const)data startingFrom:(u_int64_t)offsetInData toExtent:(const struct HFSPlusExtentDescriptor *const)oneExtent error:(NSError * _Nullable __autoreleasing *const)outError {
	void const *_Nonnull const bytesPtr = data.bytes;

	uint64_t bytesToWrite = data.length - offsetInData;
	if (bytesToWrite <= 0) {
		NSAssert(bytesToWrite >= 0, @"Invalid offset for data: This offset (%llu bytes) would start past the end of the data (%lu bytes).", offsetInData, data.length);
		return bytesToWrite;
	}

	//TODO: This is an out-of-bounds read. Does this actually make any sense? At all?
	/*
	//Only write as many bytes as will fit in this extent, and not one more.
	uint64_t const extentLengthInBytes = L(oneExtent->blockCount) * self.numberOfBytesPerBlock;
	if (extentLengthInBytes > bytesToWrite) {
		bytesToWrite = extentLengthInBytes;
	}
	 */

	u_int64_t const volumeStartInBytes = self.startOffsetInBytes;
	off_t const extentStartInBytes = L(oneExtent->startBlock) * self.numberOfBytesPerBlock;
//	ImpPrintf(@"Writing %lu bytes to output volume starting at a-block #%u (output file offset %llu bytes)", data.length, L(oneExtent->startBlock), volumeStartInBytes + extentStartInBytes);
	int64_t const amtWritten = pwrite(_fileDescriptor, bytesPtr + offsetInData, bytesToWrite, volumeStartInBytes + extentStartInBytes);

	if (amtWritten < 0) {
		NSError *_Nonnull const writeError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Failed to write 0x%llx (%llu) bytes (range of data { %llu, %lu }) starting at 0x%llx bytes", @""), bytesToWrite, bytesToWrite, offsetInData, data.length, extentStartInBytes] }];
		if (outError != NULL) {
			*outError = writeError;
		}
	}

	return amtWritten;
}

- (int64_t)writeData:(NSData *const)data startingFrom:(u_int64_t)offsetInData toExtents:(const struct HFSPlusExtentDescriptor *const)extentRec error:(NSError * _Nullable __autoreleasing *const)outError {
	int64_t totalWritten = 0;
	for (NSUInteger i = 0; i < kHFSPlusExtentDensity; ++i) {
		int64_t const amtWritten = [self writeData:data startingFrom:offsetInData toExtent:extentRec + i error:outError];
		if (amtWritten < 0) {
			return amtWritten;
		} else {
			totalWritten += amtWritten;
			offsetInData += amtWritten;
		}
	}
	return totalWritten;
}

#pragma mark ImpSourceVolume overrides
#warning These need to move to a new ImpHFSPlusSourceVolume subclass.

#if MOVE_TO_ImpHFSPlusSourceVolume
- (bool) readBootBlocksFromFileDescriptor:(int const)readFD error:(NSError *_Nullable *_Nonnull const)outError {
	_preamble = [NSMutableData dataWithLength:kISOStandardBlockSize * 3];
	ssize_t const amtRead = pread(readFD, _preamble.mutableBytes, _preamble.length, self.startOffsetInBytes + kISOStandardBlockSize * 0);
	if (amtRead < 0) {
		NSError *_Nonnull const readError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: @"Error reading volume preamble" }];
		if (outError != NULL) *outError = readError;
		return false;
	} else if ((NSUInteger)amtRead < _preamble.length) {
		NSError *_Nonnull const underrunError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:@{ NSLocalizedDescriptionKey: @"Unexpected end of file reading volume preamble — are you sure this is an HFS+ volume?" }];
		if (outError != NULL) *outError = underrunError;
		return false;
	}
	//We don't do anything with the boot blocks other than write 'em out verbatim to the HFS+ volume, but that comes later.
	return true;
}

- (bool) readVolumeHeaderFromFileDescriptor:(int const)readFD error:(NSError *_Nullable *_Nonnull const)outError {
	//The volume header occupies the third kISOStandardBlockSize bytes of the volume—i.e., the last third of the preamble.
	_vh = _preamble.mutableBytes + kISOStandardBlockSize * 2;

	if (L(_vh->signature) != kHFSPlusSigWord) {
		NSError *_Nonnull const thisIsNotHFSPlusError = [NSError errorWithDomain:NSOSStatusErrorDomain code:noMacDskErr userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Unrecognized signature 0x%04x (expected 0x%04x) in what should have been the volume header. This doesn't look like an HFS+ volume.", L(_vh->signature), kHFSPlusSigWord ] }];
		if (outError != NULL) *outError = thisIsNotHFSPlusError;
		return false;
	}

	_hasVolumeHeader = true;
	return true;
}

- (bool)readAllocationBitmapFromFileDescriptor:(const int)readFD error:(NSError * _Nullable __autoreleasing *const)outError {
	NSData *_Nonnull const bitmapData = [self readDataFromFileDescriptor:readFD
		logicalLength:L(_vh->allocationFile.logicalSize)
		bigExtents:_vh->allocationFile.extents
		numExtents:kHFSPlusExtentDensity
		error:outError];
	if (bitmapData != nil) {
		[self setAllocationBitmapData:[bitmapData mutableCopy] numberOfBits:L(_vh->totalBlocks)];
		return true;
	}
	return false;
}

- (bool)readCatalogFileFromFileDescriptor:(int const)readFD error:(NSError *_Nullable *_Nonnull const)outError {
	//TODO: We may also need to load further extents from the extents overflow file, if the catalog is particularly fragmented. Only using the extent record in the volume header may lead to only having part of the catalog.

	NSData *_Nullable const catalogFileData = [self readDataFromFileDescriptor:readFD
		logicalLength:L(_vh->catalogFile.logicalSize)
		bigExtents:_vh->catalogFile.extents
		numExtents:kHFSPlusExtentDensity
		error:outError];
//	ImpPrintf(@"Catalog file data: logical length 0x%llx bytes (%u a-blocks); read 0x%lx bytes", L(_vh->catalogFile.logicalSize), L(_vh->catalogFile.totalBlocks), catalogFileData.length);

	if (catalogFileData != nil) {
		self.catalogBTree = [[ImpBTreeFile alloc] initWithVersion:ImpBTreeVersionHFSPlusCatalog data:catalogFileData];
		if (self.catalogBTree == nil) {
			NSError *_Nonnull const noCatalogFileError = [NSError errorWithDomain:NSOSStatusErrorDomain code:badMDBErr userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedString(@"Catalog file was invalid, corrupt, or not where the volume header said it would be", @"") }];
			if (outError != NULL) {
				*outError = noCatalogFileError;
			}
		}
	}

	return (self.catalogBTree != nil);
}

- (bool)readExtentsOverflowFileFromFileDescriptor:(int const)readFD error:(NSError *_Nullable *_Nonnull const)outError {
	//IM:F says:
	//>All the areas on a volume are of fixed size and location, except for the catalog file and the extents overflow file. These two files can appear anywhere between the volume bitmap and the alternate master directory block (MDB). They can appear in any order and are not necessarily contiguous.
	//So we essentially have to treat the extents overflow file as a file.

	NSData *_Nullable const extentsFileData = [self readDataFromFileDescriptor:readFD
		logicalLength:L(_vh->extentsFile.logicalSize)
		bigExtents:_vh->extentsFile.extents
		numExtents:kHFSPlusExtentDensity
		error:outError];
//	ImpPrintf(@"Extents overflow file data: logical length 0x%llx bytes (%u a-blocks); read 0x%lx bytes", L(_vh->extentsFile.logicalSize), L(_vh->extentsFile.totalBlocks), extentsFileData.length);
	if (extentsFileData != nil) {
		self.extentsOverflowBTree = [[ImpBTreeFile alloc] initWithVersion:ImpBTreeVersionHFSPlusExtentsOverflow data:extentsFileData];
		if (self.extentsOverflowBTree == nil) {
			NSError *_Nonnull const noExtentsFileError = [NSError errorWithDomain:NSOSStatusErrorDomain code:badMDBErr userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedString(@"Extents overflow file was invalid, corrupt, or not where the volume header said it would be", @"") }];
			if (outError != NULL) {
				*outError = noExtentsFileError;
			}
		}
	}

	return (self.extentsOverflowBTree != nil);
}

//TODO: This is pretty much copied wholesale from ImpSourceVolume. It would be nice to de-dup the code somehow…
- (u_int64_t) forEachExtentInFileWithID:(HFSCatalogNodeID)cnid
	fork:(ImpForkType)forkType
	forkLogicalLength:(u_int64_t const)forkLength
	startingWithBigExtentsRecord:(struct HFSPlusExtentDescriptor const *_Nonnull const)initialExtRec
	block:(u_int64_t (^_Nonnull const)(struct HFSPlusExtentDescriptor const *_Nonnull const oneExtent, u_int64_t logicalBytesRemaining))block
{
	__block bool keepIterating = true;
	__block u_int64_t logicalBytesRemaining = forkLength;
	void (^_Nonnull const processOneExtentRecord)(struct HFSPlusExtentDescriptor const *_Nonnull const hfsExtRec, NSUInteger const numExtents) = ^(struct HFSPlusExtentDescriptor const *_Nonnull const hfsExtRec, NSUInteger const numExtents) {
		for (NSUInteger i = 0; i < numExtents && keepIterating; ++i) {
			u_int32_t const numBlocks = L(hfsExtRec[i].blockCount);
			if (numBlocks == 0) {
				break;
			}
//			ImpPrintf(@"HFS+ source: Reading extent starting at block #%u, containing %u blocks", L(hfsExtRec[i].startBlock), numBlocks);
			u_int64_t const bytesConsumed = block(&hfsExtRec[i], logicalBytesRemaining);

			if (bytesConsumed == 0) {
				ImpPrintf(@"HFS+ source: Consumer block consumed no bytes. Stopping further reads.");
				keepIterating = false;
			}

			if (bytesConsumed > logicalBytesRemaining) {
				logicalBytesRemaining = 0;
			} else {
				logicalBytesRemaining -= bytesConsumed;
			}
			if (logicalBytesRemaining == 0) {
//				ImpPrintf(@"HFS+ source: 0 bytes remaining in logical length (all bytes consumed). No further reads warranted.");
				keepIterating = false;
			}
		}
	};

	//First, process the initial extents record from the catalog.
	processOneExtentRecord(initialExtRec, kHFSPlusExtentDensity);

	//Second, if we're not done yet, consult the extents overflow B*-tree for this item.
	if (keepIterating && logicalBytesRemaining > 0) {
		ImpBTreeFile *_Nonnull const extentsFile = self.extentsOverflowBTree;

		__block u_int32_t precedingBlockCount = (u_int32_t) ImpNumberOfBlocksInHFSPlusExtentRecord(initialExtRec);
		bool keepSearching = true;
		while (keepSearching) {
			NSUInteger const numRecordsEncountered = [extentsFile searchExtentsOverflowTreeForCatalogNodeID:cnid
				fork:forkType
				precededByNumberOfBlocks:precedingBlockCount
				forEachRecord:^bool(NSData *_Nonnull const recordData)
			{
				struct HFSPlusExtentDescriptor const *_Nonnull const hfsExtRec = recordData.bytes;
				NSUInteger const numExtentDescriptors = recordData.length / sizeof(struct HFSPlusExtentDescriptor);
				processOneExtentRecord(hfsExtRec, numExtentDescriptors);
				precedingBlockCount += ImpNumberOfBlocksInHFSPlusExtentRecord(hfsExtRec);
				return keepIterating;
			}];
			keepSearching = numRecordsEncountered > 0;
		}
	}

	return forkLength - logicalBytesRemaining;
}
- (u_int64_t) forEachExtentInFileWithID:(HFSCatalogNodeID)cnid
	fork:(ImpForkType)forkType
	forkLogicalLength:(u_int64_t const)forkLength
	startingWithBigExtentsRecord:(struct HFSPlusExtentDescriptor const *_Nonnull const)hfsExtRec
	readDataOrReturnError:(NSError *_Nullable *_Nonnull const)outError
	block:(bool (^_Nonnull const)(NSData *_Nonnull const forkData, u_int64_t const logicalLength))block
{
	__block u_int64_t totalAmountRead = 0;
	__block bool ultimatelySucceeded = true;
	__block NSError *_Nullable readError = nil;

	int const readFD = self.fileDescriptor;
	u_int64_t const blockSize = self.numberOfBytesPerBlock;
	NSMutableData *_Nonnull const data = [NSMutableData dataWithLength:blockSize * L(hfsExtRec[0].blockCount)];
	__weak typeof(self) weakSelf = self;

	totalAmountRead += [self forEachExtentInFileWithID:cnid
		fork:forkType
		forkLogicalLength:forkLength
		startingWithBigExtentsRecord:hfsExtRec
		block:^u_int64_t(const struct HFSPlusExtentDescriptor *const  _Nonnull oneExtent, u_int64_t logicalBytesRemaining)
	{
//		ImpPrintf(@"Reading extent starting at #%u for %u blocks; %llu bytes remain…", L(oneExtent->startBlock), L(oneExtent->blockCount), logicalBytesRemaining);
		u_int64_t const physicalLength = blockSize * L(oneExtent->blockCount);
		u_int64_t const logicalLength = logicalBytesRemaining < physicalLength ? logicalBytesRemaining : physicalLength;
		u_int64_t amtRead = 0;
		[data setLength:logicalLength];
		bool const success = [weakSelf readIntoData:data atOffset:0 fromFileDescriptor:readFD extent:oneExtent actualAmountRead:&amtRead error:&readError];
		if (success) {
			bool const successfullyDelivered = block(data, MAX(amtRead, logicalBytesRemaining));
//			ImpPrintf(@"Consumer block returned %@; returning %llu bytes", successfullyDelivered ? @"true" : @"false", successfullyDelivered ? amtRead : 0);
			return successfullyDelivered ? amtRead : 0;
		} else {
			ultimatelySucceeded = success;
			return 0;
		}
	}];

	if (outError != NULL && readError != nil) {
		*outError = readError;
	}

	return totalAmountRead;
}
#endif

- (off_t) offsetOfFirstAllocationBlock {
	[self impluseBugDetected_messageSentToAbstractClass];
	return -1;
}

- (NSString *_Nonnull const) volumeName {
	[self impluseBugDetected_messageSentToAbstractClass];
	return @":::Volume root not found:::";
}

- (NSUInteger) numberOfBytesPerBlock {
	[self impluseBugDetected_messageSentToAbstractClass];
	return 0;
}
- (NSUInteger) numberOfBlocksTotal {
	[self impluseBugDetected_messageSentToAbstractClass];
	return 0;
}
- (NSUInteger) numberOfBlocksFree {
	[self impluseBugDetected_messageSentToAbstractClass];
	return 0;
}
- (NSUInteger) numberOfFiles {
	[self impluseBugDetected_messageSentToAbstractClass];
	return 0;
}
- (NSUInteger) numberOfFolders {
	[self impluseBugDetected_messageSentToAbstractClass];
	return 0;
}

- (NSUInteger) catalogSizeInBytes {
	[self impluseBugDetected_messageSentToAbstractClass];
	return 0;
}
- (NSUInteger) extentsOverflowSizeInBytes {
	[self impluseBugDetected_messageSentToAbstractClass];
	return 0;
}

#if MOVE_TO_ImpHFSPlusSourceVolume

#pragma mark Reading fork contents

- (NSData *_Nullable) readDataFromFileDescriptor:(int const)readFD
	logicalLength:(u_int64_t const)numBytes
	bigExtents:(struct HFSPlusExtentDescriptor const *_Nonnull const)extents
	numExtents:(NSUInteger const)numExtents
	error:(NSError *_Nullable *_Nonnull const)outError
{
	NSUInteger const blockSize = self.numberOfBytesPerBlock;
	bool successfullyReadAllNonEmptyExtents = true;

	NSNumberFormatter *_Nonnull const fmtr = [NSNumberFormatter new];
	fmtr.numberStyle = NSNumberFormatterDecimalStyle;
	fmtr.hasThousandSeparators = true;

	u_int64_t totalAmtRead = 0;

	NSMutableData *_Nonnull const data = [NSMutableData data];
	for (NSUInteger i = 0; i < numExtents; ++i) {
		if (extents[i].blockCount == 0) {
			break;
		}

		NSUInteger const destOffset = data.length;
		[data increaseLengthBy:blockSize * L(extents[i].blockCount)];

//		ImpPrintf(@"Reading extent #%lu: start block #%@, length %@ blocks", i, [fmtr stringFromNumber:@(L(extents[i].startBlock))], [fmtr stringFromNumber:@(L(extents[i].blockCount))]);
		//Note: Should never return zero because we already bailed out if blockCount is zero.
		u_int64_t amtRead = 0;
		bool const success = [self readIntoData:data
			atOffset:destOffset
			fromFileDescriptor:readFD
			startBlock:L(extents[i].startBlock)
			blockCount:L(extents[i].blockCount)
			actualAmountRead:&amtRead
			error:outError];

		totalAmtRead += amtRead;
		successfullyReadAllNonEmptyExtents = successfullyReadAllNonEmptyExtents && success;
	}
	if (successfullyReadAllNonEmptyExtents && data.length > numBytes) {
		[data setLength:numBytes];
	}

	return successfullyReadAllNonEmptyExtents ? [data copy] : nil;
}

///Convenience wrapper for the low-level method that unpacks and reads data for a single HFS extent.
- (bool) readIntoData:(NSMutableData *_Nonnull const)intoData
	atOffset:(NSUInteger)offset
	fromFileDescriptor:(int const)readFD
	extent:(struct HFSPlusExtentDescriptor const *_Nonnull const)hfsExt
	actualAmountRead:(u_int64_t *_Nonnull const)outAmtRead
	error:(NSError *_Nullable *_Nonnull const)outError
{
	return [self readIntoData:intoData
		atOffset:offset
		fromFileDescriptor:readFD
		startBlock:L(hfsExt->startBlock)
		blockCount:L(hfsExt->blockCount)
		actualAmountRead:outAmtRead
		error:outError];
}
#endif

@end
