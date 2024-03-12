//
//  ImpHFSPlusDestinationVolume.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2024-03-07.
//

#import "ImpHFSPlusDestinationVolume.h"

#import "ImpSizeUtilities.h"
#import "NSData+ImpSubdata.h"

@interface ImpHFSPlusDestinationVolume ()

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

@implementation ImpHFSPlusDestinationVolume
{
	NSMutableData *_preamble; //Boot blocks + volume header = 1.5 K
	struct HFSPlusVolumeHeader *_vh;
	CFMutableBitVectorRef _allocationsBitmap;

	///Block numbers used for allocating new extents. See ImpForkType in the .h.
	u_int32_t _highestUsedDataABlock, _lowestUsedRsrcABlock;
	//Preamble defined above.
	struct HFSPlusExtentDescriptor _preambleExtent, _postambleExtent;
	off_t _postambleStartInBytes;
	bool _hasVolumeHeader;
}

- (instancetype _Nonnull)initForWritingToFileDescriptor:(int)writeFD
	startAtOffset:(u_int64_t)startOffsetInBytes
	expectedLengthInBytes:(u_int64_t)lengthInBytes
{
	if ((self = [super initForWritingToFileDescriptor:writeFD startAtOffset:startOffsetInBytes expectedLengthInBytes:lengthInBytes])) {
		_preamble = [NSMutableData dataWithLength:kISOStandardBlockSize * 3];
		_vh = _preamble.mutableBytes + (kISOStandardBlockSize * 2);
	}
	return self;
}

#pragma mark Properties

- (NSData *) bootBlocks {
	return [_preamble dangerouslyFastSubdataWithRange_Imp:(NSRange){
		kISOStandardBlockSize * 0,
		kISOStandardBlockSize * 2,
	}];
}
- (void) setBootBlocks:(NSData *)bootBlocks {
	[_preamble replaceBytesInRange:(NSRange){
			kISOStandardBlockSize * 0,
			kISOStandardBlockSize * 2,
		}
		withBytes:bootBlocks.bytes
		length:bootBlocks.length];
}

- (NSData *) volumeHeader {
	//Not using dangerouslyFastSubdata because we're sufficiently likely to make changes to the volume header that it makes more sense to return a snapshot. (As opposed to the boot blocks, which we're copying from the HFS volume and never changing.)
	return [_preamble subdataWithRange:(NSRange){
		kISOStandardBlockSize * 2,
		kISOStandardBlockSize * 1,
	}];
}
- (void) setVolumeHeader:(NSData *)volumeHeader {
	[_preamble replaceBytesInRange:(NSRange){
			kISOStandardBlockSize * 2,
			kISOStandardBlockSize * 1,
		}
		withBytes:volumeHeader.bytes
		length:volumeHeader.length];
	_hasVolumeHeader = true;
}

- (void) peekAtHFSPlusVolumeHeader:(void (^_Nonnull const)(struct HFSPlusVolumeHeader const *_Nonnull const vhPtr NS_NOESCAPE))block {
	NSAssert(_hasVolumeHeader, @"Can't peek at volume header that hasn't been read yet");
	block(_vh);
}

- (struct HFSPlusVolumeHeader *_Nonnull const) mutableVolumeHeaderPointer {
	return _preamble.mutableBytes + kISOStandardBlockSize * 2;
}

- (void) volumeHeaderIsMostlyInitialized {
	_hasVolumeHeader = true;
}

- (off_t) offsetOfFirstAllocationBlock {
	return 0;
}

- (u_int32_t) numberOfBytesPerBlock {
	NSAssert(_hasVolumeHeader, @"Can't get the HFS+ volume's block size before the HFS+ volume's volume header has been populated");
	return L(_vh->blockSize);
}
- (NSUInteger) numberOfBlocksTotal {
	return L(_vh->totalBlocks);
}
- (NSUInteger) numberOfBlocksFree {
	return L(_vh->freeBlocks);
}
- (NSUInteger) numberOfFiles {
	return L(_vh->fileCount);
}
- (NSUInteger) numberOfFolders {
	return L(_vh->folderCount);
}

- (NSUInteger) catalogSizeInBytes {
	return L(_vh->catalogFile.logicalSize);
}
- (NSUInteger) extentsOverflowSizeInBytes {
	return L(_vh->extentsFile.logicalSize);
}

#pragma mark Block allocation bookkeeping

- (u_int32_t) numberOfBlocksFreeAccordingToWorkingBitmap {
	NSAssert(_allocationsBitmap != nil, @"Can't calculate number of free blocks on a volume that hasn't been initialized");
	CFRange searchRange = { 0, CFBitVectorGetCount(_allocationsBitmap) };
	return (u_int32_t)CFBitVectorGetCountOfBit(_allocationsBitmap, searchRange, false);
}
- (u_int32_t) firstUnusedBlockInWorkingBitmap {
	NSAssert(_allocationsBitmap != nil, @"Can't calculate number of free blocks on a volume that hasn't been initialized");
	CFRange searchRange = { 0, CFBitVectorGetCount(_allocationsBitmap) };
	return (u_int32_t)CFBitVectorGetFirstIndexOfBit(_allocationsBitmap, searchRange, false);
}

- (u_int32_t) numBlocksForPreambleWithSize:(u_int32_t const)aBlockSize {
	u_int32_t const numPreambleBlocks = (u_int32_t)[self countOfBlocksOfSize:aBlockSize neededForLogicalLength:kISOStandardBlockSize * 3];
	return numPreambleBlocks;
}
- (u_int32_t) numBlocksForPostambleWithSize:(u_int32_t const)aBlockSize {
	u_int32_t const numPostambleBlocks = (u_int32_t)[self countOfBlocksOfSize:aBlockSize neededForLogicalLength:kISOStandardBlockSize * 2];
	return numPostambleBlocks;
}

///Returns an extent describing the allocation block(s) that include this offset.
///The extent will never extend past the last allocation block; it will be truncated short if the byte count would run past the last allocation block.
///WARNINGS: This method is EXPRESSLY ALLOWED to return an extent that holds fewer than byteCount bytes, and to return a zero-length extent that starts beyond the last allocation block of the volume. (Indeed, it exists for that purpose! It's used to compute the extent occupied by the postamble, which is required to occupy the last 0x400 bytes of the volume, even if they are partially or wholly outside of the last allocation block.) You MUST check whether block numbers within this extent are valid before using them (e.g., marking them as allocated).
- (struct HFSPlusExtentDescriptor) extentFromByteOffset:(off_t const)startByteOffset size:(size_t const)byteCount {
	struct HFSPlusExtentDescriptor extent;
	size_t const aBlockSize = L(_vh->blockSize);
	size_t const numABlocks = L(_vh->totalBlocks);

	u_int32_t const firstABlock = (u_int32_t const)(startByteOffset / aBlockSize);
	S(extent.startBlock, firstABlock);
	S(extent.blockCount, (
		firstABlock < numABlocks
		? (u_int32_t const)((byteCount + (aBlockSize - 1)) / aBlockSize)
		: 0
	));

	return extent;
}


#pragma mark Block allocation machinery

///Create a new allocation bitmap that is numABlocks long. Marks the first and last few blocks as already allocated, and returns the count of those blocks.
- (u_int32_t) _createAllocationBitmapFileWithBlockSize:(u_int32_t)aBlockSize count:(u_int32_t)numABlocks {
	_allocationsBitmap = CFBitVectorCreateMutable(kCFAllocatorDefault, numABlocks);
	CFBitVectorSetCount(_allocationsBitmap, numABlocks);

	u_int32_t numBlocksUsed = 0;

	u_int32_t const firstPreambleBlock = 0; //At least the first boot block (if aBlockSize == kISOStandardBlockSize).
	u_int32_t const numPreambleBlocks = [self numBlocksForPreambleWithSize:aBlockSize];
	for (u_int32_t i = 0; i < numPreambleBlocks; ++i) {
		CFBitVectorSetBitAtIndex(_allocationsBitmap, i, true);
		++numBlocksUsed;
	}

	S(_preambleExtent.startBlock, firstPreambleBlock);
	S(_preambleExtent.blockCount, numPreambleBlocks);

	//Do this a little differently for the postamble, which isn't guaranteed to be in an allocation block. (E.g., if the allocation block size is 0x800 bytes, and the volume length is a multiple of 0x400 but not 0x800, there is no allocation block for the last 0x400 bytes—which is where the postamble goes.) So this extent may start after the last allocation block and be zero length because of that. Or it may start on an actual a-block and be one or two a-blocks long.
	//This assumes that the volume will have more than five blocks (i.e., that the preamble and postamble won't run into each other).
	u_int32_t const postambleLengthInBytes = kISOStandardBlockSize * 2;
	_postambleStartInBytes = self.lengthInBytes - postambleLengthInBytes;
	_postambleExtent = [self extentFromByteOffset:_postambleStartInBytes size:postambleLengthInBytes];
	u_int32_t const firstPostambleBlock = L(_postambleExtent.startBlock);
	u_int32_t const numPostambleBlocks = L(_postambleExtent.blockCount);
	for (u_int32_t thisBlock = firstPostambleBlock, count = 0; count < numPostambleBlocks; ++count, ++thisBlock) {
		if (thisBlock < CFBitVectorGetCount(_allocationsBitmap)) {
			CFBitVectorSetBitAtIndex(_allocationsBitmap, thisBlock, true);
			++numBlocksUsed;
		}
	}
	//And last but not least, allocate space for the allocations file that will hold our shiny new bitmap.
	u_int32_t const numAllocationsBytes = ImpCeilingDivide(numABlocks, 8);
	[self allocateBytes:numAllocationsBytes forFork:ImpForkTypeSpecialFileContents populateExtentRecord:_vh->allocationFile.extents];
//	ImpPrintf(@"Allocated the allocations file: %@", ImpDescribeHFSPlusExtentRecord(_vh->allocationFile.extents));
	_vh->allocationFile.totalBlocks = _vh->allocationFile.extents[0].blockCount;
	//DiskWarrior seems to be of the opinion that the logical length should be equal to the physical length (total size of occupied blocks). TN1150 says this is allowed, but doesn't say it's necessary.
//	S(_vh->allocationFile.logicalSize, numAllocationsBytes);
	S(_vh->allocationFile.logicalSize, L(_vh->allocationFile.totalBlocks) * L(_vh->blockSize));

	return numBlocksUsed;
}

- (void) initializeAllocationBitmapWithBlockSize:(u_int32_t)aBlockSize count:(u_int32_t)numABlocks {
	//IMPORTANT: These must be set before we attempt to initialize the allocation bitmap so the postamble offset can be computed and the corresponding bit(s), if any, set.
	S(_vh->blockSize, aBlockSize);
	S(_vh->totalBlocks, numABlocks);

	u_int32_t const numBlocksUsed = [self _createAllocationBitmapFileWithBlockSize:aBlockSize count:numABlocks];
	S(_vh->freeBlocks, numABlocks - numBlocksUsed);
	S(_vh->dataClumpSize, aBlockSize);
	S(_vh->rsrcClumpSize, aBlockSize);
	u_int32_t const nextAllocation = L(_preambleExtent.startBlock) + L(_preambleExtent.blockCount);
	S(_vh->nextAllocation, nextAllocation);
	S(_vh->nextCatalogID, kHFSFirstUserCatalogNodeID);
}

- (void) setAllocationBlockSize:(u_int32_t)aBlockSize countOfUserBlocks:(u_int32_t)numABlocks {
	//We can safely assume these will never return an unreasonable number of blocks. If the block size is the minimum, which is 0x200 bytes, these will return 3 and 2, respectively. If the block size is 0x400, they will return 2 and 1, respectively. For all other valid block sizes, they will return 1 and 1.
	u_int32_t const numPreambleBlocks = [self numBlocksForPreambleWithSize:aBlockSize];
	u_int32_t const numPostambleBlocks = [self numBlocksForPostambleWithSize:aBlockSize];
	[self initializeAllocationBitmapWithBlockSize:aBlockSize count:numPreambleBlocks + numABlocks + numPostambleBlocks];
}

///Search a range of blocks from the earliest block to the latest block for a contiguous range of available blocks that will entirely (or partially, if acceptPartial) satisfy the request.
- (bool) findBlocksForward:(u_int32_t const)requestedBlocks
	inRange:(CFRange const)wholeSearchRange
	acceptPartial:(bool const)acceptPartial
	getExtent:(struct HFSPlusExtentDescriptor *_Nonnull const)outExt
{
	if (requestedBlocks == 0) {
		//This can legitimately happen if a fork is empty, which is pretty common for files that have a data xor resource fork but not both.
		struct HFSPlusExtentDescriptor const extent = { _vh->nextAllocation, 0 };
		*outExt = extent;
		return true;
	}

	CFIndex const firstOutOfBoundsBlock = wholeSearchRange.location + wholeSearchRange.length;

	CFRange rangeToSearch = wholeSearchRange;
	CFRange rangeToAllocate = { kCFNotFound, 0 };
	while (rangeToSearch.location < firstOutOfBoundsBlock && rangeToSearch.length > 0 && rangeToAllocate.length < requestedBlocks) {
		CFIndex const firstAvailableBlockNumber = CFBitVectorGetFirstIndexOfBit(_allocationsBitmap, rangeToSearch, false);
		if (firstAvailableBlockNumber == kCFNotFound) {
			break;
		}
		CFRange const remainingRange = { firstAvailableBlockNumber, rangeToSearch.length - (firstAvailableBlockNumber - rangeToSearch.location) };
		CFIndex const lastAvailableBlockNumber = CFBitVectorGetLastIndexOfBit(_allocationsBitmap, remainingRange, false);
		rangeToAllocate = (CFRange){
			.location = firstAvailableBlockNumber,
			.length = (lastAvailableBlockNumber + 1) - firstAvailableBlockNumber,
		};
		if (rangeToAllocate.length > requestedBlocks) {
			rangeToAllocate.length = requestedBlocks;
		}
		if (rangeToAllocate.length < requestedBlocks && ! acceptPartial) {
			break;
		}

		//+2 because the block after lastAvailableBlockNumber is already known to be unavailable, so skip over it.
		CFRange nextRangeToSearch = {
			.location = lastAvailableBlockNumber + 2,
		};
		CFIndex const startToStartDistance = nextRangeToSearch.location - rangeToSearch.location;
		if (startToStartDistance > rangeToSearch.length) {
			nextRangeToSearch.length = 0;
		} else {
			nextRangeToSearch.length = rangeToSearch.length - startToStartDistance;
		}
		rangeToSearch = nextRangeToSearch;
	}

	bool const success = rangeToAllocate.length >= requestedBlocks || (acceptPartial && rangeToAllocate.location != kCFNotFound);
	if (success) {
		S(outExt->startBlock, (u_int32_t)rangeToAllocate.location);
		S(outExt->blockCount, (u_int32_t)rangeToAllocate.length);
	}

	return success;
}

///Search a range of blocks from the earliest block to the latest block for the smallest contiguous range of available blocks that will entirely (or partially, if acceptPartial) satisfy the request.
///This is an alternate, non-working implementation of the block allocator that supports filling in holes where blocks have previously been deallocated. It seeks the tightest hole that will fit the desired allocation. It would be cool if it worked, and the code is preserved here in case someone wants to give it a whack, but it's not really necessary for the case of converting a volume from another file system, which will consist entirely of allocations with no deallocations, so no hole-filling is needed.
- (bool) overlyFancy_findBlocksForward:(u_int32_t const)requestedBlocks
	inRange:(CFRange const)wholeSearchRange
	acceptPartial:(bool const)acceptPartial
	getExtent:(struct HFSPlusExtentDescriptor *_Nonnull const)outExt
{
	CFIndex const nextBlockAfterSearchRange = wholeSearchRange.location + wholeSearchRange.length;

	CFRange bestRangeSoFar = { kCFNotFound, 0 };
	CFRange searchRange = wholeSearchRange;
	while (searchRange.location != kCFNotFound && searchRange.length > 0) {
		CFIndex firstAvailableBlockNumber = CFBitVectorGetFirstIndexOfBit(_allocationsBitmap, searchRange, false);
		if (firstAvailableBlockNumber == kCFNotFound) {
			//There are no (more) available blocks. At all.
			//If we were searching from nextAllocation, our caller should try again starting from the FUAB.
			searchRange.location = kCFNotFound;
			break;
		} else {
			searchRange = (CFRange){ firstAvailableBlockNumber, requestedBlocks };

			//Note: Using CFBitVectorGetFirstIndexOfBit to find the next unavailable block won't work if the volume is completely empty (we're allocating the allocations file). We must search for the last available bit, not the next unavailable bit.
			CFIndex const lastAvailableBlockNumber = CFBitVectorGetLastIndexOfBit(_allocationsBitmap, searchRange, false);
			CFIndex const nextUnavailableBlockNumber = lastAvailableBlockNumber + 1; //Bold assuming that this is actually a valid index…

			CFRange foundRange = { firstAvailableBlockNumber, nextUnavailableBlockNumber - firstAvailableBlockNumber };
			if (foundRange.length >= requestedBlocks) {
				if (acceptPartial && bestRangeSoFar.length < requestedBlocks && foundRange.length > bestRangeSoFar.length) {
					bestRangeSoFar = foundRange;
				} else {
					if (foundRange.length == requestedBlocks) {
						//The perfect fit! Return this range immediately.
						bestRangeSoFar = foundRange;
						break;
					} else if (bestRangeSoFar.length < requestedBlocks) {
						//We hadn't previously found an extent large enough (we may or may not have accepted any partial extents), but we just did. This is our new best range, but keep looking.
						bestRangeSoFar = foundRange;
					} else if (foundRange.length < bestRangeSoFar.length) {
						//This is a better, tighter fit than our previous best range. This is our new best range, but keep looking.
						bestRangeSoFar = foundRange;
					}
				}
			} //If this is enough blocks

			//Advance the loop by searching only the blocks we haven't searched yet.
			searchRange = (CFRange) {
				nextUnavailableBlockNumber,
				nextBlockAfterSearchRange > nextUnavailableBlockNumber
				? nextBlockAfterSearchRange - nextUnavailableBlockNumber
				: 0
			};
		} //If we had any available blocks at all
	} //While the search range is not empty

	if (bestRangeSoFar.length > 0) {
		CFBitVectorSetBits(_allocationsBitmap, bestRangeSoFar, true);
		S(outExt->startBlock, (u_int32_t)bestRangeSoFar.location);
		S(outExt->blockCount, (u_int32_t)bestRangeSoFar.length);
		return true;
	}
	return false;
}

- (void) allocateBlocksOfExtent:(const struct HFSPlusExtentDescriptor *_Nonnull const)oneExtent {
	CFRange const range = {
		L(oneExtent->startBlock),
		L(oneExtent->blockCount),
	};
	CFBitVectorSetBits(_allocationsBitmap, range, true);
	S(_vh->nextAllocation, (u_int32_t)(range.location + range.length));
}

- (void) deallocateBlocksOfExtent:(const struct HFSPlusExtentDescriptor *_Nonnull const)oneExtent {
	CFRange const range = {
		L(oneExtent->startBlock),
		L(oneExtent->blockCount),
	};
	CFBitVectorSetBits(_allocationsBitmap, range, false);
}

///Grow an already-allocated extent (in one or both directions) to satisfy a requested number of blocks. Returns true if this succeeded or false if there wasn't enough space surrounding the extent to grow it to the requested size. If the extent was grown, the old extent will have been deallocated and the new extent allocated, and *outExt will have been updated with the revised extent, which is not guaranteed to overlap the original extent at all (this algorithm will not search the whole disk but will use empty space that adjoins the original extent, even if the movement would ultimately be farther than the length of the new extent). If this method returns false, no changes were made.
///Note that this method modifies the allocations map, but does not copy data.
- (bool) growAllocationFromExtent:(struct HFSPlusExtentDescriptor *_Nonnull const)outExt toBlockCount:(u_int32_t)requestedBlocks {
	u_int32_t const existingSizeOfExtent = L(outExt->blockCount);
	if (existingSizeOfExtent >= requestedBlocks) {
		//Sweet, this extent is already big enough. We're done!
		return true;
	}

	bool allocated = false;
	struct HFSPlusExtentDescriptor const backupExt = *outExt;
	bool needsRestoreIfFailed = false;

	//Before we actually try to change the size of the extent, see if we can find empty space *before* it. Whether this ends up being a partial slide or a total move, we should seek to reduce rather than create fragmentation.
	CFRange searchRange = {
		.location = [self numBlocksForPreambleWithSize:self.numberOfBytesPerBlock],
	};
	searchRange.length = L(outExt->startBlock) - searchRange.location;

	CFIndex lastAvailableBlockBeforeExistingExtent = CFBitVectorGetLastIndexOfBit(_allocationsBitmap, searchRange, false);
	if (lastAvailableBlockBeforeExistingExtent == L(outExt->startBlock) - 1) {
		//OK, there is at least one available block before the existing extent. Now find the beginning of that extent.
		CFIndex const lastUnavailableBlockBeforeExistingExtent = CFBitVectorGetLastIndexOfBit(_allocationsBitmap, searchRange, true);
		CFIndex const firstAvailableBlockBeforeExistingExtent = lastUnavailableBlockBeforeExistingExtent + 1;

		//IMPORTANT: The old extent and the new extent may overlap. In that case, the already-allocated blocks will disrupt the search—we'll think those blocks aren't available even though they're already part of the allocation we're changing. So, temporarily deallocate the existing extent and reallocate it if needed.
		[self deallocateBlocksOfExtent:outExt];
		needsRestoreIfFailed = true;

		searchRange.location = firstAvailableBlockBeforeExistingExtent;
	} else {
		//TODO: Maybe also try to slide forward?

		//Try to grow forward.
		searchRange.location = L(outExt->startBlock);
	}
	searchRange.length = requestedBlocks;

	//If the number of blocks in the search range that are already allocated equals the block count of our existing extent, then all the *other* blocks in the search range are available. Claim them.
	//(There won't be a case of *fewer* blocks in the search range already allocated because in the case where we slide backward, we deallocate the original extent above, so the entire search range should be clear at this point.)
	//If there are no blocks in the search range that are already allocated… great, they're all free. Claim them.
	CFIndex const alreadyAllocated = CFBitVectorGetCountOfBit(_allocationsBitmap, searchRange, true);
	if (alreadyAllocated == L(outExt->blockCount)) {
		S(outExt->startBlock, (u_int32_t)searchRange.location);
		S(outExt->blockCount, requestedBlocks);

		[self allocateBlocksOfExtent:outExt];
		allocated = true;
	}

	//No such luck. Restore anything we might've deallocated, then return failure.
	if (needsRestoreIfFailed && ! allocated) {
		CFRange const restoreRange = {
			L(backupExt.startBlock),
			L(backupExt.blockCount)
		};
		CFBitVectorSetBits(_allocationsBitmap, restoreRange, true);
	}

	return allocated;
}

- (bool) allocateBlocks:(u_int32_t)requestedBlocks
	forFork:(ImpForkType)forkType
	getExtent:(struct HFSPlusExtentDescriptor *_Nonnull const)outExt
{
	u_int32_t nextAllocation = L(_vh->nextAllocation);
	u_int32_t const numAllBlocks = L(_vh->totalBlocks);

	bool fulfilled = false;
	bool const verboseAllocation = false;

	struct HFSPlusExtentDescriptor backupExtent = *outExt;
	u_int32_t const existingSizeOfExtent = L(outExt->blockCount);
	if (existingSizeOfExtent > 0) {
		fulfilled = [self growAllocationFromExtent:outExt toBlockCount:requestedBlocks];
	}

	if (! fulfilled) {
		CFRange const firstSearchRange = { nextAllocation, numAllBlocks - nextAllocation };
		CFRange const secondSearchRange = { 0, nextAllocation };
		//First search for a big enough opening to satisfy the request. If there isn't one, take any opening we can find. (If the volume is fragmented, we may be able to cobble together multiple openings. If not, taking the last remaining available blocks but still needing more only delays inevitable failure.)
		fulfilled = [self findBlocksForward:requestedBlocks inRange:firstSearchRange acceptPartial:false getExtent:outExt];
		if (fulfilled) {
			if (verboseAllocation) ImpPrintf(@"Successfully allocated { %u, %u } from a sufficient opening in the latter half", L(outExt->startBlock), L(outExt->blockCount));
		} else {
			fulfilled = [self findBlocksForward:requestedBlocks inRange:secondSearchRange acceptPartial:false getExtent:outExt];
			if (fulfilled) {
				if (verboseAllocation) ImpPrintf(@"Successfully allocated { %u, %u } from a sufficient opening in the former half", L(outExt->startBlock), L(outExt->blockCount));
			} else {
				fulfilled = [self findBlocksForward:requestedBlocks inRange:firstSearchRange acceptPartial:true getExtent:outExt];
				if (fulfilled) {
					if (verboseAllocation) ImpPrintf(@"Successfully allocated { %u, %u } from a partial opening in the latter half", L(outExt->startBlock), L(outExt->blockCount));
				} else {
					fulfilled = [self findBlocksForward:requestedBlocks inRange:secondSearchRange acceptPartial:true getExtent:outExt];
					if (fulfilled) {
						if (verboseAllocation) ImpPrintf(@"Successfully allocated { %u, %u } from a partial opening in the former half", L(outExt->startBlock), L(outExt->blockCount));
					} else {
						ImpPrintf(@"Failed to allocate %u blocks", requestedBlocks);
					}
				}
			}
		}

		if (fulfilled) {
			if (existingSizeOfExtent > 0) {
				[self deallocateBlocksOfExtent:&backupExtent];
			}
			[self allocateBlocksOfExtent:outExt];
		}
	}

	return fulfilled;
}

- (u_int64_t) allocateBytes:(u_int64_t)numBytes
	forFork:(ImpForkType)forkType
	populateExtentRecord:(struct HFSPlusExtentDescriptor *_Nonnull const)outExts
{
	u_int32_t const aBlockSize = self.numberOfBytesPerBlock;
	u_int64_t remaining = numBytes;
	NSUInteger extentIdx = 0;

	//Skip over any extents already populated.
	u_int32_t blockCount = 0;
	while ((blockCount = L(outExts[extentIdx].blockCount)) != 0 && extentIdx < kHFSPlusExtentDensity) {
		u_int64_t const thisExtentInBytes = blockCount * aBlockSize;
		if (remaining > thisExtentInBytes) {
			remaining -= thisExtentInBytes;
		} else {
			remaining = 0;
		}
		++extentIdx;
	}

	while (remaining > 0 && extentIdx < kHFSPlusExtentDensity) {
		//How big of an extent do we need for this number of bytes?
		u_int64_t numBlocksThisExtent = [self countOfBlocksOfSize:aBlockSize neededForLogicalLength:remaining];
		if (numBlocksThisExtent > UINT32_MAX) numBlocksThisExtent = UINT32_MAX;

		//Try to allocate that many.
		bool allocated = [self allocateBlocks:(u_int32_t)numBlocksThisExtent forFork:forkType getExtent:outExts + extentIdx];

		//Whatever we allocated, deduct it from our number of bytes remaining and advance to the next slot in the extent record.
		if (allocated) {
			numBlocksThisExtent = L(outExts[extentIdx].blockCount);
			u_int64_t const numBytesAllocated = aBlockSize * numBlocksThisExtent;
			if (numBytesAllocated < remaining) {
				remaining -= numBytesAllocated;
			} else {
				remaining = 0;
			}
			++extentIdx;
		} else {
			//Well then. We failed to allocate anything at all. Either we're *completely* out of space (largest unused extent was zero), or something else is wrong.
			//TODO: Probably should warn or something about having failed to allocate enough blocks. Maybe an NSError return?
			//TODO: Deallocate any extents we did allocate.
			ImpPrintf(@"Block allocation failure: Tried to allocate 0x%llx bytes for fork 0x%02x but fell 0x%llx bytes short", numBytes, forkType, remaining);
			break;
		}
	}

	//remaining can be non-zero for either of two reasons:
	//- The extent record filled up, and further extents will need to be added to the extents overflow file.
	//- Allocation failure.
	return remaining;
}

#pragma mark Volume writing

- (bool) writeTemporaryPreamble:(out NSError *_Nullable *_Nullable const)outError {
	NSString *_Nonnull const preambleText0 = (
		@"This volume is in the process of being translated from HFS to HFS+. It should not be mounted (especially not as read-write) until the translation is complete.\n"
		@"The following block (0x200) contains the original volume header in case restoration is necessary. The volume header in the usual place (0x400) will be overwritten with another message so that Disk Arb or other HFS+ tools do not recognize it and try to mount it and risk wrecking the conversion.\n"
		@"Stay safe, and death to fascism. See you on the flip side."
	);
	NSString *_Nonnull const preambleText1 = (
		@"Looking for your data?\n"
		@"If this message is still here, your data was not all copied to this volume. The conversion failed. *Do not* trust this copy!!\n"
		@"Try converting again; if it still fails, please report a bug. If you can attach the original volume to the bug report (which may mean uploading it somewhere and giving the link, if too big to attach directly), please do.\n"
		@"If you want to try mounting this volume, copy the preceding block (0x200) over this block (0x400). This should then be mountable.\n"
		@"Good luck..."
	);
	NSData *_Nonnull const preambleData0 = [preambleText0 dataUsingEncoding:NSUTF8StringEncoding];
	NSAssert(preambleData0.length == kISOStandardBlockSize, @"Temporary preamble chunk #0 was wrong length; needed to be 0x%x bytes, but got 0x%lx bytes", kISOStandardBlockSize, preambleData0.length);
	NSData *_Nonnull const preambleData1 = [preambleText1 dataUsingEncoding:NSUTF8StringEncoding];
	NSAssert(preambleData1.length == kISOStandardBlockSize, @"Temporary preamble chunk #1 was wrong length; needed to be 0x%x bytes, but got 0x%lx bytes", kISOStandardBlockSize, preambleData1.length);

	u_int64_t const volumeStartInBytes = self.startOffsetInBytes;
	ssize_t amtWritten = pwrite(self.fileDescriptor, preambleData0.bytes, preambleData0.length, volumeStartInBytes + 0);
	if (amtWritten < 0 || (NSUInteger)amtWritten < preambleData0.length) {
		NSError *_Nonnull const cantWriteTempPreambleChunk0Error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedString(@"Could not write temporary preamble chunk #0 to converted volume", @"") }];
		if (outError != NULL) {
			*outError = cantWriteTempPreambleChunk0Error;
		}
		return false;
	}

	NSData *_Nonnull const volumeHeader = self.volumeHeader;
	amtWritten = pwrite(self.fileDescriptor, volumeHeader.bytes, volumeHeader.length, volumeStartInBytes + preambleData0.length);
	if (amtWritten < 0 || (NSUInteger)amtWritten < volumeHeader.length) {
		NSError *_Nonnull const cantWriteVolumeHeaderError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedString(@"Could not write converted volume header in temporary location", @"") }];
		if (outError != NULL) {
			*outError = cantWriteVolumeHeaderError;
		}
		return false;
	}

	amtWritten = pwrite(self.fileDescriptor, preambleData1.bytes, preambleData1.length, volumeStartInBytes + preambleData0.length + preambleData1.length);
	if (amtWritten < 0 || (NSUInteger)amtWritten < preambleData1.length) {
		NSError *_Nonnull const cantWriteTempPreambleChunk2Error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedString(@"Could not write temporary preamble chunk #2 to converted volume", @"") }];
		if (outError != NULL) {
			*outError = cantWriteTempPreambleChunk2Error;
		}
		return false;
	}

	return true;
}

- (bool) flushVolumeStructures:(NSError *_Nullable *_Nullable const)outError {
//	ImpPrintf(@"Writing final allocations file");
	NSUInteger const numABlocks = self.numberOfBlocksTotal;
	NSMutableData *_Nonnull const bitmapData = [NSMutableData dataWithLength:ImpCeilingDivide(numABlocks, 8)];
	CFBitVectorGetBits(_allocationsBitmap, (CFRange){ 0, numABlocks }, bitmapData.mutableBytes);
	if (! [self writeData:bitmapData startingFrom:0 toExtents:_vh->allocationFile.extents error:outError]) {
		return false;
	}

//	ImpPrintf(@"Writing real boot blocks");
	u_int64_t const volumeStartInBytes = self.startOffsetInBytes;
	NSData *_Nonnull const bootBlocks = self.bootBlocks;
	ssize_t amtWritten = pwrite(self.fileDescriptor, bootBlocks.bytes, bootBlocks.length, volumeStartInBytes + 0);
	if (amtWritten < 0 || (NSUInteger)amtWritten < bootBlocks.length) {
		NSError *_Nonnull const cantWriteBootBlocksError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedString(@"Could not copy boot blocks from original volume to converted volume", @"") }];
		if (outError != NULL) {
			*outError = cantWriteBootBlocksError;
		}
		return false;
	}

//	ImpPrintf(@"Writing final volume header");
	NSData *_Nonnull const volumeHeader = self.volumeHeader;
//	struct HFSPlusVolumeHeader const *_Nonnull const vh = volumeHeader.bytes;
//	ImpPrintf(@"Final catalog file will be %llu bytes in %u blocks", L(vh->catalogFile.logicalSize), L(vh->catalogFile.totalBlocks));
//	ImpPrintf(@"Final extents overflow file will be %llu bytes in %u blocks", L(vh->extentsFile.logicalSize), L(vh->extentsFile.totalBlocks));

	amtWritten = pwrite(self.fileDescriptor, volumeHeader.bytes, volumeHeader.length, volumeStartInBytes + bootBlocks.length);
	if (amtWritten < 0 || (NSUInteger)amtWritten < volumeHeader.length) {
		NSError *_Nonnull const cantWriteVolumeHeaderError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedString(@"Could not write converted volume header", @"") }];
		if (outError != NULL) {
			*outError = cantWriteVolumeHeaderError;
		}
		return false;
	}

//	ImpPrintf(@"Writing postamble");
	//The postamble is the last 1 K of the volume, containing the alternate volume header and the footer.
	//The postamble needs to be in the very last 1 K of the disk, regardless of where the a-block boundary is. TN1150 is explicit that this region can lie outside of an a-block and any a-blocks it does lie inside of must be marked as used.
	amtWritten = pwrite(self.fileDescriptor, volumeHeader.bytes, volumeHeader.length, volumeStartInBytes + _postambleStartInBytes);
	if (amtWritten < 0 || (NSUInteger)amtWritten < volumeHeader.length) {
		NSError *_Nonnull const cantWriteAltVolumeHeaderError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedString(@"Could not write alternate volume header", @"") }];
		if (outError != NULL) {
			*outError = cantWriteAltVolumeHeaderError;
		}
		return false;
	}
	off_t const lastHalfKStart = _postambleStartInBytes + kISOStandardBlockSize;
	NSMutableData *_Nonnull const emptyHalfK = [NSMutableData dataWithLength:kISOStandardBlockSize];
	NSData *_Nonnull const lastBlock = self.lastBlock ?: emptyHalfK;
	amtWritten = pwrite(self.fileDescriptor, lastBlock.bytes, lastBlock.length, volumeStartInBytes + lastHalfKStart);
	if (amtWritten < 0 || (NSUInteger)amtWritten < lastBlock.length) {
		NSError *_Nonnull const cantWriteAltVolumeHeaderError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedString(@"Could not write alternate volume header", @"") }];
		if (outError != NULL) {
			*outError = cantWriteAltVolumeHeaderError;
		}
		return false;
	}

	return true;
}

@end
