//
//  ImpHFSPlusVolume.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-26.
//

#import "ImpHFSPlusVolume.h"

#import "NSData+ImpSubdata.h"
#import "ImpSizeUtilities.h"

#import <sys/stat.h>
#import <hfs/hfs_format.h>

//For implementing the read side
#import "ImpTextEncodingConverter.h"
#import "ImpBTreeFile.h"

@interface ImpVirtualFileHandle ()

///Create a new virtual file handle backed by an HFS+ volume (and its backing file descriptor). extentRecPtr must be a pointer to a populated HFS+ extent record (at least kHFSPlusExtentDensity extent descriptors).
- (instancetype _Nonnull) initWithVolume:(ImpHFSPlusVolume *_Nonnull const)dstVol extents:(struct HFSPlusExtentDescriptor const *_Nonnull const)extentRecPtr;

@end

@interface ImpHFSPlusVolume ()

- (u_int32_t) numBlocksForPreambleWithSize:(u_int32_t const)aBlockSize;
- (u_int32_t) numBlocksForPostambleWithSize:(u_int32_t const)aBlockSize;

///Low-level method. Marks the blocks within the extent as allocated.
///WARNING: This method does not check that these blocks are available/not already allocated. It is meant for implementing higher-level allocation methods, such as those declared in the header, that do perform such checks. You probably want one of those.
- (void) allocateBlocksOfExtent:(const struct HFSPlusExtentDescriptor *_Nonnull const)oneExtent;

///Low-level method. Marks the blocks within the extent as unallocated (available).
///WARNING: This method does not check that these blocks are allocated, nor does it make sure nothing is using these blocks. It is meant for implementing higher-level allocation and deallocation methods, such as those declared in the header, that do perform such checks. You probably want one of those.
- (void) deallocateBlocksOfExtent:(const struct HFSPlusExtentDescriptor *_Nonnull const)oneExtent;

@end

@implementation ImpHFSPlusVolume
{
	NSMutableData *_preamble; //Boot blocks + volume header = 1.5 K
	struct HFSPlusVolumeHeader *_vh;
	CFMutableBitVectorRef _allocationsBitmap;

	int _writeFD;
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
	if ((self = [super init])) {
		_writeFD = writeFD;

		_startOffsetInBytes = startOffsetInBytes;
		_lengthInBytes = lengthInBytes;

		_preamble = [NSMutableData dataWithLength:kISOStandardBlockSize * 3];
		_vh = _preamble.mutableBytes + (kISOStandardBlockSize * 2);
	}
	return self;
}

- (bool) flushVolumeStructures:(NSError *_Nullable *_Nullable const)outError {
	NSUInteger const numABlocks = self.numberOfBlocksTotal;
	NSMutableData *_Nonnull const bitmapData = [NSMutableData dataWithLength:(numABlocks + 7) / 8];
	CFBitVectorGetBits(_allocationsBitmap, (CFRange){ 0, numABlocks }, bitmapData.mutableBytes);
	if (! [self writeData:bitmapData startingFrom:0 toExtents:_vh->allocationFile.extents error:outError]) {
		return false;
	}

	u_int64_t const volumeStartInBytes = self.startOffsetInBytes;
	NSData *_Nonnull const bootBlocks = self.bootBlocks;
	ssize_t amtWritten = pwrite(_writeFD, bootBlocks.bytes, bootBlocks.length, volumeStartInBytes + 0);
	if (amtWritten < bootBlocks.length) {
		NSError *_Nonnull const cantWriteBootBlocksError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedString(@"Could not copy boot blocks from original volume to converted volume", @"") }];
		if (outError != NULL) {
			*outError = cantWriteBootBlocksError;
		}
		return false;
	}

	NSData *_Nonnull const volumeHeader = self.volumeHeader;
//	struct HFSPlusVolumeHeader const *_Nonnull const vh = volumeHeader.bytes;
//	ImpPrintf(@"Final catalog file will be %llu bytes in %u blocks", L(vh->catalogFile.logicalSize), L(vh->catalogFile.totalBlocks));
//	ImpPrintf(@"Final extents overflow file will be %llu bytes in %u blocks", L(vh->extentsFile.logicalSize), L(vh->extentsFile.totalBlocks));

	amtWritten = pwrite(_writeFD, volumeHeader.bytes, volumeHeader.length, volumeStartInBytes + bootBlocks.length);
	if (amtWritten < volumeHeader.length) {
		NSError *_Nonnull const cantWriteVolumeHeaderError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedString(@"Could not write converted volume header", @"") }];
		if (outError != NULL) {
			*outError = cantWriteVolumeHeaderError;
		}
		return false;
	}

	//The postamble is the last 1 K of the volume, containing the alternate volume header and the footer.
	//The postamble needs to be in the very last 1 K of the disk, regardless of where the a-block boundary is. TN1150 is explicit that this region can lie outside of an a-block and any a-blocks it does lie inside of must be marked as used.
	off_t const last1KStart = self.lengthInBytes - (kISOStandardBlockSize * 2);
	amtWritten = pwrite(_writeFD, volumeHeader.bytes, volumeHeader.length, volumeStartInBytes + last1KStart);
	if (amtWritten < volumeHeader.length) {
		NSError *_Nonnull const cantWriteAltVolumeHeaderError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedString(@"Could not write alternate volume header", @"") }];
		if (outError != NULL) {
			*outError = cantWriteAltVolumeHeaderError;
		}
		return false;
	}

	return true;
}

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

- (void) peekAtHFSVolumeHeader:(void (^_Nonnull const)(struct HFSMasterDirectoryBlock const *_Nonnull const mdbPtr NS_NOESCAPE))block {
	NSAssert(false, @"%@ sent to %@", NSStringFromSelector(_cmd), self);
}
- (void) peekAtHFSPlusVolumeHeader:(void (^_Nonnull const)(struct HFSPlusVolumeHeader const *_Nonnull const vhPtr NS_NOESCAPE))block {
	NSAssert(_hasVolumeHeader, @"Can't peek at volume header that hasn't been read yet");
	block(_vh);
}

- (struct HFSPlusVolumeHeader *_Nonnull const) mutableVolumeHeaderPointer {
	return _preamble.mutableBytes + kISOStandardBlockSize * 2;
}

- (u_int32_t) numberOfBlocksFreeAccordingToWorkingBitmap {
	NSAssert(_allocationsBitmap != nil, @"Can't calculate number of free blocks on a volume that hasn't been initialized");
	CFRange searchRange = { 0, CFBitVectorGetCount(_allocationsBitmap) };
	return (u_int32_t)CFBitVectorGetCountOfBit(_allocationsBitmap, searchRange, false);
}

- (u_int32_t) blockSize {
	NSAssert(_hasVolumeHeader, @"Can't get the HFS+ volume's block size before the HFS+ volume's volume header has been populated");
	return L(_vh->blockSize);
}

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
	u_int32_t const numAllocationsBytes = (numABlocks + 7) / 8;
	[self allocateBytes:numAllocationsBytes forFork:ImpForkTypeSpecialFileContents populateExtentRecord:_vh->allocationFile.extents];
	_vh->allocationFile.totalBlocks = _vh->allocationFile.extents[0].blockCount;
	//DiskWarrior seems to be of the opinion that the logical length should be equal to the physical length (total size of occupied blocks). TN1150 says this is allowed, but doesn't say it's necessary.
//	S(_vh->allocationFile.logicalSize, numAllocationsBytes);
	S(_vh->allocationFile.logicalSize, L(_vh->allocationFile.totalBlocks) * L(_vh->blockSize));

	return numBlocksUsed;
}

///Search the allocations bitmap for a range of unused blocks at least requestedNumABlocks long. If no such range exists, reduces requestedNumABlocks and tries again. Returns the length of an available extent, in a-blocks.
//TODO: Would it be better to make this a block-allocating method? Find such a range, then immediately allocate it and return its extent?
//TODO: Also, this currently doesn't take a forkType. The search should proceed in a direction determined by forkType (searching for openings for data forks from the end). (… although isn't that just allocateBlocks:forFork:getExtent:?)
//TODO: Possible optimization (if we add the forkType thing): If we encounter a big extent of open space that includes the 25% or 50% marks of the drive (between the resources world and the data world), stop the search there. If we've already found a suitable range, use that; else, carve one out of the big pool in the middle and use that.
- (u_int32_t) countOfBlocksInLargestUnusedExtentUpToCount:(u_int32_t)requestedNumABlocks {
	CFRange initialRange = {
		L(_vh->nextAllocation),
		0,
	};
	//We could use totalBlocks (all a-blocks), but the postamble is always occupied anyway so there's no point searching for available a-blocks there.
	CFIndex const numBlocksBeforePostamble = L(_postambleExtent.startBlock);
	initialRange.length = numBlocksBeforePostamble - initialRange.location;

	CFRange currentBestRange = { 0, 0 };

	u_int32_t numBlocksFound = 0;
	while (numBlocksFound == 0) {
		CFRange range = initialRange;
		CFIndex indexOfFirstUnusedBlock = CFBitVectorGetFirstIndexOfBit(_allocationsBitmap, range, false);
		if (indexOfFirstUnusedBlock == kCFNotFound) {
			if (initialRange.location > 0) {
				//Hm. Maybe nextAllocation is past some unused blocks; that can happen (in theory). Try searching the portion of the disk before nextAllocation.
				//Also, since a lack of unused blocks after nextAllocation is not going to change, reset our initialRange to the whole disk for the sake of future loops.
				initialRange.location = 0;
				initialRange.length = L(_vh->nextAllocation);
				indexOfFirstUnusedBlock = CFBitVectorGetFirstIndexOfBit(_allocationsBitmap, range, false);
				if (indexOfFirstUnusedBlock == kCFNotFound) {
					//Nope, no unused blocks at all. Bummer.
					break;
				}
			}
		}

		while (range.location < numBlocksBeforePostamble) {
			range.location = indexOfFirstUnusedBlock;
			range.length = numBlocksBeforePostamble - range.location;
			CFIndex indexOfLastUnusedBlock = CFBitVectorGetLastIndexOfBit(_allocationsBitmap, range, false);
			range.length = indexOfLastUnusedBlock - indexOfFirstUnusedBlock;
			if (range.length >= requestedNumABlocks) {
				if (range.length - requestedNumABlocks < currentBestRange.length - requestedNumABlocks) {
					//This is a better fit for this number of blocks. This is our new best range.
					currentBestRange = range;
				}
			}
			range.location = indexOfLastUnusedBlock + 1;
			range.length = numBlocksBeforePostamble - range.location;
		}

		numBlocksFound = (u_int32_t)currentBestRange.length;
	}

	return numBlocksFound;
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

- (void) setAllocationBlockSize:(u_int32_t)aBlockSize countOfUserBlocks:(u_int32_t)numABlocks {
	//We can safely assume these will never return an unreasonable number of blocks. If the block size is the minimum, which is 0x200 bytes, these will return 3 and 2, respectively. If the block size is 0x400, they will return 2 and 1, respectively. For all other valid block sizes, they will return 1 and 1.
	u_int32_t const numPreambleBlocks = [self numBlocksForPreambleWithSize:aBlockSize];
	u_int32_t const numPostambleBlocks = [self numBlocksForPostambleWithSize:aBlockSize];
	[self initializeAllocationBitmapWithBlockSize:aBlockSize count:numPreambleBlocks + numABlocks + numPostambleBlocks];
}

#pragma mark Block allocation

///Search a range of blocks from the earliest block to the latest block for a contiguous range of available blocks that will entirely (or partially, if acceptPartial) satisfy the request.
- (bool) findBlocksForward:(u_int32_t const)requestedBlocks
	inRange:(CFRange const)wholeSearchRange
	acceptPartial:(bool const)acceptPartial
	getExtent:(struct HFSPlusExtentDescriptor *_Nonnull const)outExt
{
	if (requestedBlocks == 0) {
		//This can legitimately happen if a fork is empty, which is pretty common for files that have a data xor resource fork but not both.
		struct HFSPlusExtentDescriptor extent = { _vh->nextAllocation, 0 };
		*outExt = extent;
		return true;
	}

	CFRange rangeToSearch = wholeSearchRange;
	CFRange rangeToAllocate = { kCFNotFound, 0 };
	while (rangeToAllocate.length < requestedBlocks) {
		CFIndex const firstAvailableBlockNumber = CFBitVectorGetFirstIndexOfBit(_allocationsBitmap, rangeToSearch, false);
		if (firstAvailableBlockNumber == kCFNotFound) {
			break;
		}
		CFRange const remainingRange = { firstAvailableBlockNumber, rangeToSearch.length - (firstAvailableBlockNumber - rangeToSearch.location) };
		CFIndex const lastAvailableBlockNumber = CFBitVectorGetLastIndexOfBit(_allocationsBitmap, remainingRange, false);
		rangeToAllocate = (CFRange){ firstAvailableBlockNumber, (lastAvailableBlockNumber + 1) - firstAvailableBlockNumber };
		if (rangeToAllocate.length > requestedBlocks) {
			rangeToAllocate.length = requestedBlocks;
		}
		if (rangeToAllocate.length < requestedBlocks && ! acceptPartial) {
			break;
		}
	}

	bool const success = rangeToAllocate.length >= requestedBlocks || (acceptPartial && rangeToAllocate.location != kCFNotFound);
	if (success) {
		CFBitVectorSetBits(_allocationsBitmap, rangeToAllocate, true);
		S(outExt->startBlock, (u_int32_t)rangeToAllocate.location);
		S(outExt->blockCount, (u_int32_t)rangeToAllocate.length);
		S(_vh->nextAllocation, (u_int32_t)(rangeToAllocate.location + rangeToAllocate.length));
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
		.location = [self numBlocksForPreambleWithSize:L(_vh->blockSize)],
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

	struct HFSPlusExtentDescriptor backupExtent = *outExt;
	u_int32_t const existingSizeOfExtent = L(outExt->blockCount);
	if (existingSizeOfExtent > 0) {
		fulfilled = [self growAllocationFromExtent:outExt toBlockCount:requestedBlocks];
	}

	if (! fulfilled) {
		CFRange searchRange = { nextAllocation, numAllBlocks - nextAllocation };
		fulfilled = [self findBlocksForward:requestedBlocks inRange:searchRange acceptPartial:false getExtent:outExt];
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
	u_int32_t const aBlockSize = self.blockSize;
	u_int64_t remaining = numBytes;
	NSUInteger extentIdx = 0;
	while (remaining > 0 && extentIdx < kHFSPlusExtentDensity) {
		//How big of an extent do we need for this number of bytes?
		u_int64_t numBlocksThisExtent = [self countOfBlocksOfSize:aBlockSize neededForLogicalLength:remaining];
		if (numBlocksThisExtent > UINT32_MAX) numBlocksThisExtent = UINT32_MAX;

		//Try to allocate that many.
		bool allocated = [self allocateBlocks:(u_int32_t)numBlocksThisExtent forFork:forkType getExtent:outExts + extentIdx];
		if (! allocated) {
			//OK, maybe not. What's the biggest extent we *can* allocate out of this volume?
			numBlocksThisExtent = [self countOfBlocksInLargestUnusedExtentUpToCount:(u_int32_t)numBlocksThisExtent];
			//Try to allocate that.
			allocated = [self allocateBlocks:(u_int32_t)numBlocksThisExtent forFork:forkType getExtent:outExts + extentIdx];
		}

		//Whatever we allocated, deduct it from our number of bytes remaining and advance to the next slot in the extent record.
		if (allocated) {
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
			ImpPrintf(@"Block allocation failure: Tried to allocate %llu bytes for fork 0x%02x but fell %llu bytes short", numBytes, forkType, remaining);
			break;
		}
	}

	//remaining can be non-zero for either of two reasons:
	//- The extent record filled up, and further extents will need to be added to the extents overflow file.
	//- Allocation failure.
	return remaining;
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
	uint64_t const extentLengthInBytes = L(oneExtent->blockCount) * self.blockSize;
	if (extentLengthInBytes > bytesToWrite) {
		bytesToWrite = extentLengthInBytes;
	}
	 */

	u_int64_t const volumeStartInBytes = self.startOffsetInBytes;
	off_t const extentStartInBytes = L(oneExtent->startBlock) * self.blockSize;
	int64_t const amtWritten = pwrite(_writeFD, bytesPtr + offsetInData, bytesToWrite, volumeStartInBytes + extentStartInBytes);

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
	ssize_t amtWritten = pwrite(_writeFD, preambleData0.bytes, preambleData0.length, volumeStartInBytes + 0);
	if (amtWritten < preambleData0.length) {
		NSError *_Nonnull const cantWriteTempPreambleChunk0Error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedString(@"Could not write temporary preamble chunk #0 to converted volume", @"") }];
		if (outError != NULL) {
			*outError = cantWriteTempPreambleChunk0Error;
		}
		return false;
	}

	NSData *_Nonnull const volumeHeader = self.volumeHeader;
	amtWritten = pwrite(_writeFD, volumeHeader.bytes, volumeHeader.length, volumeStartInBytes + preambleData0.length);
	if (amtWritten < volumeHeader.length) {
		NSError *_Nonnull const cantWriteVolumeHeaderError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedString(@"Could not write converted volume header in temporary location", @"") }];
		if (outError != NULL) {
			*outError = cantWriteVolumeHeaderError;
		}
		return false;
	}

	amtWritten = pwrite(_writeFD, preambleData1.bytes, preambleData1.length, volumeStartInBytes + preambleData0.length + preambleData1.length);
	if (amtWritten < preambleData1.length) {
		NSError *_Nonnull const cantWriteTempPreambleChunk2Error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedString(@"Could not write temporary preamble chunk #2 to converted volume", @"") }];
		if (outError != NULL) {
			*outError = cantWriteTempPreambleChunk2Error;
		}
		return false;
	}

	return true;

}

#pragma mark ImpHFSVolume overrides

- (bool) readBootBlocksFromFileDescriptor:(int const)readFD error:(NSError *_Nullable *_Nonnull const)outError {
	_preamble = [NSMutableData dataWithLength:kISOStandardBlockSize * 3];
	ssize_t const amtRead = pread(readFD, _preamble.mutableBytes, _preamble.length, self.startOffsetInBytes + kISOStandardBlockSize * 0);
	if (amtRead < _preamble.length) {
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
	ImpPrintf(@"Catalog file data: logical length 0x%llx bytes (%u a-blocks); read 0x%lx bytes", L(_vh->catalogFile.logicalSize), L(_vh->catalogFile.totalBlocks), catalogFileData.length);

	if (catalogFileData != nil) {
		self.catalogBTree = [[ImpBTreeFile alloc] initWithVersion:ImpBTreeVersionHFSPlusCatalog data:catalogFileData];
		if (self.catalogBTree == nil) {
			NSError *_Nonnull const noCatalogFileError = [NSError errorWithDomain:NSOSStatusErrorDomain code:badMDBErr userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedString(@"Catalog file was invalid, corrupt, or not where the volume header said it would be", @"") }];
			if (outError != NULL) {
				*outError = noCatalogFileError;
			}
		}
	}
	ImpPrintf(@"Catalog file is using %lu nodes out of an allocated %lu (%.2f%% utilization)", self.catalogBTree.numberOfLiveNodes, self.catalogBTree.numberOfPotentialNodes, self.catalogBTree.numberOfPotentialNodes > 0 ? (self.catalogBTree.numberOfLiveNodes / (double)self.catalogBTree.numberOfPotentialNodes) * 100.0 : 1.0);

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
	ImpPrintf(@"Extents overflow file data: logical length 0x%llx bytes (%u a-blocks); read 0x%lx bytes", L(_vh->extentsFile.logicalSize), L(_vh->extentsFile.totalBlocks), extentsFileData.length);
	if (extentsFileData != nil) {
		self.extentsOverflowBTree = [[ImpBTreeFile alloc] initWithVersion:ImpBTreeVersionHFSPlusExtentsOverflow data:extentsFileData];
		if (self.extentsOverflowBTree == nil) {
			NSError *_Nonnull const noExtentsFileError = [NSError errorWithDomain:NSOSStatusErrorDomain code:badMDBErr userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedString(@"Extents overflow file was invalid, corrupt, or not where the volume header said it would be", @"") }];
			if (outError != NULL) {
				*outError = noExtentsFileError;
			}
		}
	}
	ImpPrintf(@"Extents file is using %lu nodes out of an allocated %lu (%.2f%% utilization)", self.extentsOverflowBTree.numberOfLiveNodes, self.extentsOverflowBTree.numberOfPotentialNodes, self.extentsOverflowBTree.numberOfPotentialNodes > 0 ? (self.extentsOverflowBTree.numberOfLiveNodes / (double)self.extentsOverflowBTree.numberOfPotentialNodes) * 100.0 : 1.0);

	return (self.extentsOverflowBTree != nil);
}

//TODO: This is pretty much copied wholesale from ImpHFSVolume. It would be nice to de-dup the code somehow…
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
//			ImpPrintf(@"Reading extent starting at block #%u, containing %u blocks", L(hfsExtRec[i].startBlock), numBlocks);
			u_int64_t const bytesConsumed = block(&hfsExtRec[i], logicalBytesRemaining);

			if (bytesConsumed == 0) {
				ImpPrintf(@"Consumer block consumed no bytes. Stopping further reads.");
				keepIterating = false;
			}

			if (bytesConsumed > logicalBytesRemaining) {
				logicalBytesRemaining = 0;
			} else {
				logicalBytesRemaining -= bytesConsumed;
			}
			if (logicalBytesRemaining == 0) {
//				ImpPrintf(@"0 bytes remaining in logical length (all bytes consumed). No further reads warranted.");
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

- (bool) isBlockAllocated:(u_int32_t const)blockNumber {
	if (_allocationsBitmap != nil) {
		return CFBitVectorGetBitAtIndex(_allocationsBitmap, blockNumber);
	} else {
		//We're reading the allocations bitmap. Just claim any block we're reading for it is allocated.
		return true;
	}
}

- (off_t) offsetOfFirstAllocationBlock {
	return 0;
}

- (NSString *_Nonnull const) volumeName {
	//Unlike in HFS, where the volume name is conveniently part of the volume header, in HFS+ we actually have to look up the root directory and get its name.
	NSData *_Nullable threadRecData = nil;
	struct HFSUniStr255 const emptyName = { .length = 0 };
	bool const foundRootDirectory = [self.catalogBTree searchCatalogTreeForItemWithParentID:kHFSRootFolderID unicodeName:&emptyName getRecordKeyData:NULL threadRecordData:&threadRecData];
	if (foundRootDirectory) {
		struct HFSPlusCatalogThread const *_Nonnull const threadRecPtr = threadRecData.bytes;
		return [self.textEncodingConverter stringFromHFSUniStr255:&(threadRecPtr->nodeName)];
	}
	return @":::Volume root not found:::";
}

- (NSUInteger) numberOfBytesPerBlock {
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

		[data increaseLengthBy:blockSize * L(extents[i].blockCount)];

		ImpPrintf(@"Reading extent #%lu: start block #%@, length %@ blocks", i, [fmtr stringFromNumber:@(L(extents[i].startBlock))], [fmtr stringFromNumber:@(L(extents[i].blockCount))]);
		//Note: Should never return zero because we already bailed out if blockCount is zero.
		u_int64_t amtRead = 0;
		bool const success = [self readIntoData:data
			atOffset:0
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

@end

@implementation ImpVirtualFileHandle
{
	__block ImpHFSPlusVolume *_Nonnull _backingVolume;
	NSMutableData *_Nonnull _extentsData;
	struct HFSPlusExtentDescriptor *_Nonnull _extentsPtr;
	NSUInteger _numExtents;
	NSUInteger _numExtentsIncludingEmpties; //Always a multiple of kHFSPlusExtentDensity
	NSMutableData *_Nonnull dataNotYetWritten;
	u_int64_t _bytesWrittenSoFar; //Effectively the file mark
	u_int32_t _blockSize;
	u_int32_t _currentExtentIndex;
	struct HFSPlusExtentDescriptor _remainderOfCurrentExtent;
}

- (instancetype _Nonnull) initWithVolume:(ImpHFSPlusVolume *_Nonnull const)dstVol extents:(struct HFSPlusExtentDescriptor const *_Nonnull const)extentRecPtr {
	if ((self = [super init])) {
		_backingVolume = dstVol;

		_extentsData = [NSMutableData dataWithLength:sizeof(struct HFSPlusExtentDescriptor) * kHFSPlusExtentDensity];
		_extentsPtr = _extentsData.mutableBytes;
		NSUInteger totalSize = 0;
		for (NSUInteger i = 0; i < kHFSPlusExtentDensity; ++i) {
			NSUInteger const blockCount = extentRecPtr[i].blockCount;
			if (blockCount == 0) {
				break;
			}

			totalSize += blockCount * _backingVolume.blockSize;
			_extentsPtr[i] = extentRecPtr[i];

			++_numExtents;
		}
		_numExtentsIncludingEmpties += kHFSPlusExtentDensity;

		_totalPhysicalSize = totalSize;
		_blockSize = dstVol.blockSize;
		dataNotYetWritten = [NSMutableData dataWithCapacity:_blockSize * 2];
	}
	return self;
}

- (void) growIntoExtents:(struct HFSPlusExtentDescriptor const *_Nonnull const)extentRecPtr {
	enum { sizeOfOneExtentRecord = sizeof(struct HFSPlusExtentDescriptor) * kHFSPlusExtentDensity };

	for (NSUInteger srcIdx = 0, destIdx = _numExtents; srcIdx < kHFSPlusExtentDensity; ++srcIdx, ++destIdx) {
		NSUInteger const blockCount = extentRecPtr[srcIdx].blockCount;
		if (blockCount == 0) {
			break;
		}

		if (destIdx == _numExtentsIncludingEmpties) {
			[_extentsData increaseLengthBy:sizeOfOneExtentRecord];
			_extentsPtr = _extentsData.mutableBytes;
			_numExtentsIncludingEmpties += kHFSPlusExtentDensity;
		}

		_extentsPtr[destIdx] = extentRecPtr[srcIdx];
		++_numExtents;
	}
}

///Divvy up an extent according to the length of some data.
///The first extent is the portion of the whole extent to which some of the data can be written in whole blocks.
///The remainder bytes is the number of bytes at the end of data that aren't a whole block. (That is, the remainder of dividing the data's length by the block size, *plus* any blocks that might not have fit in the whole extent if the whole extent was too short.)
///The second (following) extent is the portion of the whole extent that follows the first extent. Concatenating the first and second extents will always recreate the whole extent.
///The return value is the number of bytes that will fit in the first extent (i.e., the dividend of the same division from which remainderBytes is the remainder).
///For example, say the block size is 0x200 bytes and you want to split a data whose length is 0x900 bytes. If the whole extent is 0xa00 bytes (5 blocks), then the first extent will be 0x800, the remainder will be 0x100, and the second extent will be 0x200.
///If the whole extent is only 0x600 bytes (3 blocks), then the first extent will be 0x600, the remainder will be 0x300 (0x900 - 0x600), and the second extent will be empty.
- (u_int64_t) splitExtent:(struct HFSPlusExtentDescriptor const *_Nonnull const)wholeExtent
	usingData:(NSData *_Nonnull const)data
	intoExtent:(struct HFSPlusExtentDescriptor *_Nonnull const)outExtentThatCoversData
	andRemainderBytes:(u_int64_t *_Nonnull const)outRemainderBytes
	andFollowingExtent:(struct HFSPlusExtentDescriptor *_Nonnull const)outExtentThatFollowsData
{
	u_int32_t const aBlockSizeInBytes = _backingVolume.blockSize;
	u_int32_t const wholeExtentLengthInABlocks = L(wholeExtent->blockCount);

	u_int64_t const dataLengthInBytes = data.length;
	u_int64_t const dataLengthInABlocksNotIncludingRemainder = dataLengthInBytes / aBlockSizeInBytes;
	u_int64_t dividendInBytes = dataLengthInABlocksNotIncludingRemainder * aBlockSizeInBytes;
	u_int64_t remainderBytes = dataLengthInBytes % aBlockSizeInBytes;

	struct HFSPlusExtentDescriptor firstExtent;
	struct HFSPlusExtentDescriptor secondExtent;

	if (dataLengthInABlocksNotIncludingRemainder <= wholeExtentLengthInABlocks) {
		//The whole extent is at least big enough to fit the whole data.
		firstExtent.startBlock = wholeExtent->startBlock; //Not swapped because we're copying as-is
		S(firstExtent.blockCount, (u_int32_t)dataLengthInABlocksNotIncludingRemainder);

		S(secondExtent.startBlock, (u_int32_t)(L(firstExtent.startBlock) + dataLengthInABlocksNotIncludingRemainder));
		S(secondExtent.blockCount, (u_int32_t)(L(wholeExtent->blockCount) - dataLengthInABlocksNotIncludingRemainder));
	} else {
		//The data is too long to fit in the whole extent. Return the whole extent and the number of bytes we had nowhere to put.
		firstExtent.startBlock = wholeExtent->startBlock; //Not swapped because we're copying as-is
		firstExtent.blockCount = wholeExtent->blockCount; //Not swapped because we're copying as-is
		secondExtent = (struct HFSPlusExtentDescriptor){ 0, 0 };
		u_int64_t const numBytesAssignedToAnExtent = L(firstExtent.blockCount) * aBlockSizeInBytes;
		dividendInBytes = numBytesAssignedToAnExtent;
		remainderBytes = dataLengthInBytes - numBytesAssignedToAnExtent;
	}

	*outExtentThatCoversData = firstExtent;
	*outExtentThatFollowsData = secondExtent;
	*outRemainderBytes = remainderBytes;
	return dividendInBytes;
}

- (NSInteger) writeData:(NSData *_Nonnull const)data error:(NSError *_Nullable *_Nonnull const)outError {
	NSInteger bytesWrittenSoFar = 0;

	//If we have a leftover partial block, re-write it with some or all of this data appended.
	//If this data still isn't enough to fill out the block, then we need to leave it appended for the next write's benefit.
	//If we did append enough to fill out a block, then we can empty the leftover bucket and advance the extent by 1 block, to either write out the rest of this data (if there is any) or the next data (if there is any).
	NSUInteger offsetIntoData = 0;
	NSUInteger const numBytesLeftOver = dataNotYetWritten.length;
	NSUInteger const numBytesRemainingInBlock = _blockSize - numBytesLeftOver;
	if (numBytesLeftOver > 0) {
		NSRange const rangeOfFirstPortion = {
			0,
			data.length < numBytesRemainingInBlock ? data.length : numBytesRemainingInBlock
		};
		NSData *_Nonnull const firstPortion = [data dangerouslyFastSubdataWithRange_Imp:rangeOfFirstPortion];
		[dataNotYetWritten appendData:firstPortion];
		NSInteger bytesWrittenThisTime = [_backingVolume writeData:dataNotYetWritten startingFrom:bytesWrittenSoFar toExtent:&_remainderOfCurrentExtent error:outError];
		if (bytesWrittenThisTime < 0) {
			bytesWrittenSoFar = bytesWrittenThisTime;
		} else {
			bytesWrittenSoFar += bytesWrittenThisTime;
			offsetIntoData += rangeOfFirstPortion.length;

			if (rangeOfFirstPortion.length == _blockSize) {
				//We've now written one (1) full block at the start of this extent, so remove it from the extent still to be written.
				S(_remainderOfCurrentExtent.startBlock, L(_remainderOfCurrentExtent.startBlock) + 1);
				S(_remainderOfCurrentExtent.blockCount, L(_remainderOfCurrentExtent.blockCount) - 1);
				if (_remainderOfCurrentExtent.blockCount == 0) {
					++_currentExtentIndex;
				}

				//Also empty out the leftovers bucket.
				[dataNotYetWritten setLength:0];
			}
		}
	}

	while (bytesWrittenSoFar >= 0 && data.length - bytesWrittenSoFar >= _blockSize) {
		if (_remainderOfCurrentExtent.blockCount == 0) {
			if (_currentExtentIndex >= _numExtents) {
				break;
			}
			_remainderOfCurrentExtent = _extentsPtr[_currentExtentIndex];
		}

		struct HFSPlusExtentDescriptor extentToWrite, extentAfterThat;
		u_int64_t remainderBytes;
		u_int64_t const dividendBytes = [self splitExtent:&_remainderOfCurrentExtent usingData:data intoExtent:&extentToWrite andRemainderBytes:&remainderBytes andFollowingExtent:&extentAfterThat];

		NSRange const rangeToWrite = { bytesWrittenSoFar, dividendBytes };
		NSData *_Nonnull const dataToWrite = [data dangerouslyFastSubdataWithRange_Imp:rangeToWrite];

		NSInteger bytesWrittenThisTime = [_backingVolume writeData:dataToWrite startingFrom:offsetIntoData toExtent:&extentToWrite error:outError];
		if (bytesWrittenThisTime < 0) {
			bytesWrittenSoFar = bytesWrittenThisTime;
			break;
		}

		bytesWrittenSoFar += bytesWrittenThisTime;
		offsetIntoData += bytesWrittenThisTime;
		_remainderOfCurrentExtent = extentAfterThat;
		if (extentAfterThat.blockCount == 0) {
			++_currentExtentIndex;
		}
	}

	if (data.length > bytesWrittenSoFar && _currentExtentIndex < _numExtents) {
		if (_remainderOfCurrentExtent.blockCount == 0) {
			_remainderOfCurrentExtent = _extentsPtr[_currentExtentIndex];
		}

		//Write out the remainder of this data without advancing the mark. We'll pad it with zeroes to a full block for this last write, but then leave it in the buffer unpadded so that if another write comes in, we can prepend this data to the next data to overwrite the block.
		[dataNotYetWritten setData:[data subdataWithRange:(NSRange){ bytesWrittenSoFar, data.length - bytesWrittenSoFar }]];
//		NSUInteger const numBytesNotYetWritten = dataNotYetWritten.length;

//		[dataNotYetWritten setLength:_blockSize]; //This should extend rather than truncate, since we're going from a partial block to a full block.
		NSInteger bytesWrittenThisTime = [_backingVolume writeData:dataNotYetWritten startingFrom:0 toExtent:&_remainderOfCurrentExtent error:outError];
		if (bytesWrittenThisTime < 0) {
			bytesWrittenSoFar = bytesWrittenThisTime;
		} else {
			bytesWrittenSoFar += bytesWrittenThisTime;
		}
//		[dataNotYetWritten setLength:numBytesNotYetWritten]; //Trim back to the actual leftover data length.

		//Note that we do not advance the extent because if another write comes in, we'll need to rewrite this block with some data appended to the leftover (see first section of method).
	}

	return bytesWrittenSoFar;
}

- (void) closeFile {
	//TODO: Implement me
}

@end
