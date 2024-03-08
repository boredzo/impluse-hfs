//
//  ImpSourceVolume.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-26.
//

#import "ImpSourceVolume.h"

#import "ImpByteOrder.h"
#import "ImpPrintf.h"
#import "ImpSizeUtilities.h"
#import "ImpForkUtilities.h"
#import "NSData+ImpSubdata.h"
#import "ImpTextEncodingConverter.h"
#import "ImpExtentSeries.h"
#import "ImpBTreeFile.h"

#import "ImpHFSSourceVolume.h"

@interface ImpSourceVolume ()

@property(readwrite, nonnull, strong) ImpTextEncodingConverter *textEncodingConverter;

@end

@implementation ImpSourceVolume
{
	NSData *_lastBlockData;
	NSMutableData *_volumeBitmapData;
	CFMutableBitVectorRef _blocksThatAreAllocatedButWereNotAccessed;
}

- (void) impluseBugDetected_messageSentToAbstractClass {
	NSAssert(false, @"Message %s sent to instance of class %@, which hasn't implemented it (instance of abstract class, method not overridden, or super called when it shouldn't have been)", sel_getName(_cmd), [self class]);
}

- (instancetype _Nonnull) initWithFileDescriptor:(int const)readFD
	startOffsetInBytes:(u_int64_t)startOffset
	lengthInBytes:(u_int64_t)lengthInBytes
	textEncoding:(TextEncoding const)hfsTextEncoding
{
	if ((self = [super init])) {
		_fileDescriptor = readFD;
		_startOffsetInBytes = startOffset;
		_lengthInBytes = lengthInBytes;
		_textEncodingConverter = [[ImpTextEncodingConverter alloc] initWithHFSTextEncoding:hfsTextEncoding];
	}
	return self;
}

- (void) dealloc {
	if (_bitVector != NULL) {
		CFRelease(_bitVector);
	}
}

- (bool) readBootBlocksFromFileDescriptor:(int const)readFD error:(NSError *_Nullable *_Nonnull const)outError {
	_bootBlocksData = [NSMutableData dataWithLength:kISOStandardBlockSize * 2];
	ssize_t const amtRead = pread(readFD, _bootBlocksData.mutableBytes, _bootBlocksData.length, _startOffsetInBytes + kISOStandardBlockSize * 0);
	if (amtRead < 0) {
		NSError *_Nonnull const readError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: @"Error reading source volume boot blocks" }];
		if (outError != NULL) *outError = readError;
		return false;
	} else if ((NSUInteger)amtRead < _bootBlocksData.length) {
		NSError *_Nonnull const underrunError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:@{ NSLocalizedDescriptionKey: @"Unexpected end of file reading source volume boot blocks — are you sure this is an HFS volume?" }];
		if (outError != NULL) *outError = underrunError;
		return false;
	}
	//We don't do anything with the boot blocks other than write 'em out verbatim to the HFS+ volume, but that comes later.
	return true;
}

- (bool) readVolumeHeaderFromFileDescriptor:(int const)readFD error:(NSError *_Nullable *_Nonnull const)outError {
	[self impluseBugDetected_messageSentToAbstractClass];
	return false;
}

- (void) setAllocationBitmapData:(NSMutableData *_Nonnull const)bitmapData numberOfBits:(u_int32_t const)numBits {
	_volumeBitmapData = bitmapData;
	_bitVector = CFBitVectorCreate(kCFAllocatorDefault, _volumeBitmapData.bytes, numBits);

	_blocksThatAreAllocatedButWereNotAccessed = CFBitVectorCreateMutableCopy(kCFAllocatorDefault, numBits, _bitVector);
}

- (bool)readAllocationBitmapFromFileDescriptor:(int const)readFD error:(NSError *_Nullable *_Nonnull const)outError {
	[self impluseBugDetected_messageSentToAbstractClass];
	return false;
}
- (bool)readCatalogFileFromFileDescriptor:(int const)readFD error:(NSError *_Nullable *_Nonnull const)outError {
	[self impluseBugDetected_messageSentToAbstractClass];
	return false;
}
- (bool)readExtentsOverflowFileFromFileDescriptor:(int const)readFD error:(NSError *_Nullable *_Nonnull const)outError {
	[self impluseBugDetected_messageSentToAbstractClass];
	return false;
}

- (bool) readLastBlockFromFileDescriptor:(int const)readFD error:(NSError *_Nullable *_Nonnull const)outError {
	NSMutableData *_Nonnull const lastBlockData = [NSMutableData dataWithLength:kISOStandardBlockSize];
	ssize_t const amtRead = pread(readFD, lastBlockData.mutableBytes, lastBlockData.length, _startOffsetInBytes + _lengthInBytes - kISOStandardBlockSize);
	if (amtRead < 0) {
		NSError *_Nonnull const readError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: @"Error reading source volume last block" }];
		if (outError != NULL) *outError = readError;
		return false;
	} else if ((NSUInteger)amtRead < lastBlockData.length) {
		NSError *_Nonnull const underrunError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:@{ NSLocalizedDescriptionKey: @"Unexpected end of file reading source volume last block — are you sure this is an HFS volume?" }];
		if (outError != NULL) *outError = underrunError;
		return false;
	}
	//We don't do anything with the last block other than write it out verbatim to the HFS+ volume, but that comes later.
	_lastBlockData = lastBlockData;
	return true;
}

- (bool)loadAndReturnError:(NSError *_Nullable *_Nonnull const)outError {
	int const readFD = self.fileDescriptor;
	return (
		[self readBootBlocksFromFileDescriptor:readFD error:outError]
		&&
		[self readVolumeHeaderFromFileDescriptor:readFD error:outError]
		&&
		[self readAllocationBitmapFromFileDescriptor:readFD error:outError]
		&&
		[self readExtentsOverflowFileFromFileDescriptor:readFD error:outError]
		&&
		[self readCatalogFileFromFileDescriptor:readFD error:outError]
		&&
		[self readLastBlockFromFileDescriptor:readFD error:outError]
	);
}

#pragma mark -

- (NSData *_Nullable) dataForBlocksStartingAt:(u_int32_t const)startBlock count:(u_int32_t const)blockCount {
	NSUInteger const blockSize = self.numberOfBytesPerBlock;
	NSMutableData *_Nonnull const intoData = [NSMutableData dataWithLength:blockSize * blockCount];
	off_t const readStart = self.startOffsetInBytes + self.offsetOfFirstAllocationBlock + startBlock * blockSize;
	enum { offset = 0 };
	size_t const numBytesToRead = intoData.length - offset;
	ssize_t const amtRead = pread(self.fileDescriptor, intoData.mutableBytes + offset, numBytesToRead, readStart);
	return amtRead > 0 ? intoData : nil;
}
- (NSData *_Nullable) dataForBlock:(u_int32_t)aBlock {
	return [self dataForBlocksStartingAt:aBlock count:1];
}

- (bool) readIntoData:(NSMutableData *_Nonnull const)intoData
	atOffset:(NSUInteger)offset
	fromFileDescriptor:(int const)readFD
	startBlock:(u_int32_t const)startBlock
	blockCount:(u_int32_t const)blockCount
	actualAmountRead:(u_int64_t *_Nonnull const)outAmtRead
	error:(NSError *_Nullable *_Nonnull const)outError
{
	int32_t firstUnallocatedBlockNumber = -1;
	//TODO: Optimize using CFBitVectorGetCountOfBit (start range at startBlock, check returned count >= blockCount)
	for (u_int16_t i = 0; i < blockCount; ++i) {
//		ImpPrintf(@"- #%u: %@", startBlock + i, CFBitVectorGetBitAtIndex(_bitVector, startBlock + i) ? @"YES" : @"NO!");
		if (! [self isBlockAllocated:startBlock + i]) {
			firstUnallocatedBlockNumber = startBlock + i;
		}
	}
//	ImpPrintf(@"Extent starting at %u is fully allocated before reading: %@", startBlock, (firstUnallocatedBlockNumber < 0) ? @"YES" : @"NO");
	if (firstUnallocatedBlockNumber > -1) {
		//It's possible that this should be a warning, or that its level of fatality should be adjustable (particularly in situations of data recovery).
		NSError *_Nonnull const readingIntoTheVoidError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Attempt to read block #%u, which is unallocated; this may indicate a bug in this program, or that the volume itself was corrupt (please save a copy of it using bzip2)", @""), firstUnallocatedBlockNumber] }];
		if (outError != NULL) {
			*outError = readingIntoTheVoidError;
		}
		return false;
	}

	off_t const readStart = self.startOffsetInBytes + self.offsetOfFirstAllocationBlock + startBlock * self.numberOfBytesPerBlock;
	size_t const numBytesToRead = intoData.length - offset;
	size_t const numBlocksToRead = ImpCeilingDivide(intoData.length, self.numberOfBytesPerBlock);
	if (_blocksThatAreAllocatedButWereNotAccessed != NULL) {
		CFBitVectorSetBits(_blocksThatAreAllocatedButWereNotAccessed, (CFRange) { startBlock, numBlocksToRead }, false);
	}
//	ImpPrintf(@"Reading 0x%lx bytes (%lu bytes = %lu blocks) from source volume starting at 0x%llx bytes (extent: [ start #%u, %u blocks ])", intoData.length, intoData.length, ImpCeilingDivide(intoData.length, self.numberOfBytesPerBlock), readStart, startBlock, blockCount);
	if (numBlocksToRead < blockCount) {
		NSLog(@"Underrun alert! Data is not big enough to hold this extent. Only reading %zu blocks out of this extent's %u blocks", numBlocksToRead, blockCount);
	}
	ssize_t const amtRead = pread(readFD, intoData.mutableBytes + offset, numBytesToRead, readStart);
	if (outAmtRead != NULL) {
		*outAmtRead = amtRead;
	}
	if (amtRead < 0) {
		NSError *_Nonnull const readFailedError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to read data from extent { start #%u, %u blocks }", (unsigned)startBlock, (unsigned)blockCount ] }];
		if (outError != NULL) {
			*outError = readFailedError;
		}
		return false;
	}

	return true;
}

///Convenience wrapper for the low-level method that unpacks and reads data for a single HFS extent.
- (bool) readIntoData:(NSMutableData *_Nonnull const)intoData
	atOffset:(NSUInteger)offset
	fromFileDescriptor:(int const)readFD
	extent:(struct HFSExtentDescriptor const *_Nonnull const)hfsExt
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

- (NSData *_Nullable) readDataFromFileDescriptor:(int const)readFD
	logicalLength:(u_int64_t const)numBytes
	extents:(struct HFSExtentDescriptor const *_Nonnull const)extents
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
			extent:&extents[i]
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

- (bool) checkHFSExtentRecord:(HFSExtentRecord const *_Nonnull const)hfsExtRec {
	struct HFSExtentDescriptor const *_Nonnull const hfsExtDescs = (struct HFSExtentDescriptor const *_Nonnull const)hfsExtRec;
	NSUInteger const firstStartBlock = hfsExtDescs[0].startBlock;
	NSUInteger const firstNextBlock = firstStartBlock + hfsExtDescs[0].blockCount;
	NSUInteger const secondStartBlock = hfsExtDescs[1].startBlock;
	NSUInteger const secondNextBlock = secondStartBlock + hfsExtDescs[1].blockCount;
	NSUInteger const thirdStartBlock = hfsExtDescs[2].startBlock;
	NSUInteger const thirdNextBlock = thirdStartBlock + hfsExtDescs[2].blockCount;
	if (firstNextBlock == secondStartBlock || secondNextBlock == thirdStartBlock) {
		//These are two adjacent extents. Bit odd if they're short enough that they could be one extent, but not a problem.
		//Note that firstNextBlock == thirdStartBlock is not adjacency: they are adjacent on disk, but the second extent comes between them in the file.
	}
	if (firstNextBlock > secondStartBlock && firstNextBlock < secondNextBlock) {
		//The first extent overlaps the second extent. While it might seem like the foundation of an overly-clever compressor, it would be an invalid state from which to make changes to files (changing a block in the intersection would change the file in two places), so it's an inconsistency.
		return false;
	}
	if (secondNextBlock > thirdStartBlock && secondNextBlock < thirdNextBlock) {
		//The second extent overlaps the third extent. While it might seem like the foundation of an overly-clever compressor, it would be an invalid state from which to make changes to files (changing a block in the intersection would change the file in two places), so it's an inconsistency.
		return false;
	}

	if (
		(hfsExtDescs[0].blockCount > 0)
		&&
		(! (hfsExtDescs[1].blockCount > 0))
		&&
		(hfsExtDescs[2].blockCount > 0)
	) {
		//We have two non-empty extents on either side of an empty extent.
		//This… seems sus. The question is, does an extent record end at the first empty extent (so this record effectively only contains one extent) or is every extent included, and empty extents simply contribute nothing to the file (so this record effectively contains two extents)?
		//I don't know what Classic Mac OS does in this situation, and neither Inside Macintosh nor the technotes have anything to say on the topic.
		//FWIW, modern macOS stops at the first empty extent, so the third extent would be ignored. <https://opensource.apple.com/source/hfs/hfs-407.30.1/core/FileExtentMapping.c.auto.html>
		//It does seem like a state you could only arrive at by either directly editing the catalog (setting the second extent's blockCount to zero, but leaving the third unchanged) to remove blocks from the middle of the file, or by corruption.
		//For now, allow it. The implementation above of reading using an extent record currently stops at the first empty extent, which (by coincidence) turns out to be consistent with Apple's implementation.
	}

	return true;
}

#pragma mark -

- (NSData *_Nonnull)bootBlocks {
	return _bootBlocksData;
}
- (NSData *_Nonnull)lastBlock {
	return _lastBlockData;
}
- (NSData *_Nonnull) volumeBitmap {
	return _volumeBitmapData;
}

- (bool) isBlockInBounds:(u_int32_t const)blockNumber {
	return blockNumber < self.numberOfBlocksTotal;
}
- (bool) isBlockAllocated:(u_int32_t const)blockNumber {
	return CFBitVectorGetBitAtIndex(_bitVector, blockNumber);
}

- (u_int32_t) numberOfBlocksFreeAccordingToBitmap {
	return (u_int32_t)CFBitVectorGetCountOfBit(_bitVector, (CFRange){ 0, self.numberOfBlocksTotal }, false);
}

- (void) reportBlocksThatAreAllocatedButHaveNotBeenAccessed {
	CFRange const entireRange = { 0, self.numberOfBlocksTotal };
	CFRange searchRange = entireRange;
	CFRange foundRange;
	while ((foundRange.location = CFBitVectorGetFirstIndexOfBit(_blocksThatAreAllocatedButWereNotAccessed, searchRange, true)) != kCFNotFound) {
		searchRange.length -= foundRange.location - searchRange.location;
		searchRange.location = foundRange.location;

		CFIndex const lastMissedBit = CFBitVectorGetLastIndexOfBit(_blocksThatAreAllocatedButWereNotAccessed, searchRange, true);
		foundRange.length = (lastMissedBit - foundRange.location) + 1;
		ImpPrintf(@"Blocks that have not been accessed: %lu through %lu (%lu blocks)", foundRange.location, lastMissedBit, foundRange.length);

		searchRange.length -= foundRange.length;
		searchRange.location += foundRange.length;
	}
	NSUInteger const numUnreadBlocks = CFBitVectorGetCountOfBit(_blocksThatAreAllocatedButWereNotAccessed, entireRange, true);
	if (numUnreadBlocks > 0) {
		ImpPrintf(@"Of the %lu blocks that are marked as allocated, %lu have not been read from", CFBitVectorGetCountOfBit(_bitVector, entireRange, true), numUnreadBlocks);
	}
}
- (NSUInteger) numberOfBlocksThatAreAllocatedButHaveNotBeenAccessed {
	CFRange const entireRange = { 0, self.numberOfBlocksTotal };
	NSUInteger const numUnreadBlocks = CFBitVectorGetCountOfBit(_blocksThatAreAllocatedButWereNotAccessed, entireRange, true);
	if (numUnreadBlocks > 0) {
		ImpPrintf(@"Of the %lu blocks that are marked as allocated, %lu have not been read from", CFBitVectorGetCountOfBit(_bitVector, entireRange, true), numUnreadBlocks);
	}

	return numUnreadBlocks;
}
- (void) findExtents:(void (^_Nonnull const)(NSRange))block inBitVector:(CFBitVectorRef _Nonnull const)bitVector {
	CFRange const entireRange = { 0, self.numberOfBlocksTotal };
	CFRange searchRange = entireRange;
	CFRange foundRange;
	while ((foundRange.location = CFBitVectorGetFirstIndexOfBit(bitVector, searchRange, true)) != kCFNotFound) {
		searchRange.length -= foundRange.location - searchRange.location;
		searchRange.location = foundRange.location;

		CFIndex const lastMissedBit = CFBitVectorGetLastIndexOfBit(bitVector, searchRange, true);
		foundRange.length = (lastMissedBit - foundRange.location) + 1;

		NSRange const extent = { foundRange.location, foundRange.length };
		block(extent);

		searchRange.length -= foundRange.length;
		searchRange.location += foundRange.length;
	}
}
- (void) findExtentsThatAreAllocatedButHaveNotBeenAccessed:(void (^_Nonnull const)(NSRange))block {
	[self findExtents:block inBitVector:_blocksThatAreAllocatedButWereNotAccessed];
}
- (void) findExtentsThatAreAllocatedButAreNotReferencedInTheBTrees:(void (^_Nonnull const)(NSRange))block {
	[self impluseBugDetected_messageSentToAbstractClass];
}
- (NSUInteger) numberOfBlocksThatAreAllocatedButAreNotReferencedInTheBTrees {
	__block NSUInteger numOrphanedBlocks = 0;
	[self findExtentsThatAreAllocatedButAreNotReferencedInTheBTrees:^(NSRange extentRange) {
		numOrphanedBlocks += extentRange.length;
	}];
	if (numOrphanedBlocks > 0) {
		CFRange const entireRange = { 0, self.numberOfBlocksTotal };
		ImpPrintf(@"Of the %lu blocks that are marked as allocated, %lu are not claimed by any fork", CFBitVectorGetCountOfBit(_bitVector, entireRange, true), numOrphanedBlocks);
	}

	return numOrphanedBlocks;
}

- (u_int64_t) lengthInBytes {
	return (
		_lengthInBytes > 0
		? _lengthInBytes
		: self.numberOfBytesPerBlock * (u_int64_t)self.numberOfBlocksTotal
	);
}

- (u_int32_t) firstPhysicalBlockOfFirstAllocationBlock {
	[self impluseBugDetected_messageSentToAbstractClass];
	return 0;
}
- (off_t) offsetOfFirstAllocationBlock {
	[self impluseBugDetected_messageSentToAbstractClass];
	return -1;
}
- (NSString *_Nonnull) volumeName {
	[self impluseBugDetected_messageSentToAbstractClass];
	return @"Unknown volume";
}
- (NSUInteger) numberOfBytesPerBlock {
	[self impluseBugDetected_messageSentToAbstractClass];
	return 0;
}
- (NSUInteger) numberOfBlocksTotal {
	[self impluseBugDetected_messageSentToAbstractClass];
	return 0;
}
- (NSUInteger) numberOfBlocksUsed {
	return self.numberOfBlocksTotal - self.numberOfBlocksFree;
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

- (u_int64_t) forEachExtentInFileWithID:(HFSCatalogNodeID)cnid
	fork:(ImpForkType)forkType
	forkLogicalLength:(u_int64_t const)forkLength
	startingWithExtentsRecord:(struct HFSExtentDescriptor const *_Nonnull const)initialExtRec
	block:(u_int64_t (^_Nonnull const)(struct HFSExtentDescriptor const *_Nonnull const oneExtent, u_int64_t logicalBytesRemaining))block
{
	__block bool keepIterating = true;
	__block u_int64_t logicalBytesRemaining = forkLength;
	void (^_Nonnull const processOneExtentRecord)(struct HFSExtentDescriptor const *_Nonnull const hfsExtRec, NSUInteger const numExtents) = ^(struct HFSExtentDescriptor const *_Nonnull const hfsExtRec, NSUInteger const numExtents) {
		for (NSUInteger i = 0; i < numExtents && keepIterating; ++i) {
			u_int16_t const numBlocks = L(hfsExtRec[i].blockCount);
			if (numBlocks == 0) {
				break;
			}
//			ImpPrintf(@"HFS source: Reading extent starting at block #%u, containing %u blocks", L(hfsExtRec[i].startBlock), numBlocks);
			u_int64_t const bytesConsumed = block(&hfsExtRec[i], logicalBytesRemaining);

			if (bytesConsumed == 0) {
				ImpPrintf(@"HFS source: Consumer block consumed no bytes. Stopping further reads.");
				keepIterating = false;
			}

			if (bytesConsumed > logicalBytesRemaining) {
				logicalBytesRemaining = 0;
			} else {
				logicalBytesRemaining -= bytesConsumed;
			}
		}
	};

	//First, process the initial extents record from the catalog.
	processOneExtentRecord(initialExtRec, kHFSExtentDensity);

	//Second, if we're not done yet, consult the extents overflow B*-tree for this item.
	if (keepIterating && logicalBytesRemaining > 0) {
//		ImpPrintf(@"Still need to find %llu bytes. Looking in the extents overflow file…", logicalBytesRemaining);
		ImpBTreeFile *_Nonnull const extentsFile = self.extentsOverflowBTree;

		__block u_int32_t precedingBlockCount = ImpNumberOfBlocksInHFSExtentRecord(initialExtRec);
		bool keepSearching = true;
		while (keepSearching) {
			NSUInteger const numRecordsEncountered = [extentsFile searchExtentsOverflowTreeForCatalogNodeID:cnid
			fork:forkType
				precededByNumberOfBlocks:precedingBlockCount
			forEachRecord:^bool(NSData *_Nonnull const recordData)
		{
			struct HFSExtentDescriptor const *_Nonnull const hfsExtRec = recordData.bytes;
			NSUInteger const numExtentDescriptors = recordData.length / sizeof(struct HFSExtentDescriptor);
			processOneExtentRecord(hfsExtRec, numExtentDescriptors);
				precedingBlockCount += ImpNumberOfBlocksInHFSExtentRecord(hfsExtRec);
			return keepIterating;
		}];
			keepSearching = numRecordsEncountered > 0;
		}
	}

	return forkLength - logicalBytesRemaining;
}

///For each extent in the file, call the block with the data contained in that extent and the logical length of it. The logical length will equal the physical length (block size times block count) for extents that aren't the last in the file; for the last extent, the logical length may be shorter than the physical length. For extraction, you should only use the first logicalLength bytes of the file; for conversion to HFS+, you should use the full NSData (copy the full allocation block, including unused data).
///Returns the physical length read. Unless your block returns false at any point, or an error occurs, this should equal the total size in bytes of all consecutive non-empty extents.
- (u_int64_t) forEachExtentInFileWithID:(HFSCatalogNodeID)cnid
	fork:(ImpForkType)forkType
	forkLogicalLength:(u_int64_t const)forkLength
	startingWithExtentsRecord:(struct HFSExtentDescriptor const *_Nonnull const)hfsExtRec
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
		startingWithExtentsRecord:hfsExtRec
		block:^u_int64_t(const struct HFSExtentDescriptor *const  _Nonnull oneExtent, u_int64_t logicalBytesRemaining)
	{
//		ImpPrintf(@"Reading extent starting at #%u for %u blocks; %llu bytes remain…", L(oneExtent->startBlock), L(oneExtent->blockCount), logicalBytesRemaining);
		u_int64_t const physicalLength = blockSize * L(oneExtent->blockCount);

		u_int64_t amtRead = 0;
		[data setLength:physicalLength];
		bool const success = [weakSelf readIntoData:data
			atOffset:0
			fromFileDescriptor:readFD
			extent:oneExtent
			actualAmountRead:&amtRead
			error:&readError];

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

@end
