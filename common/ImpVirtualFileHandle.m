//
//  ImpVirtualFileHandle.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2024-03-07.
//

#import "ImpVirtualFileHandle.h"

#import "NSData+ImpSubdata.h"

#import "ImpDestinationVolume.h"
#import "ImpHFSPlusDestinationVolume.h"

@implementation ImpVirtualFileHandle
{
	ImpDestinationVolume *_Nonnull _backingVolume;
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

- (instancetype _Nonnull) initWithVolume:(ImpDestinationVolume *_Nonnull const)dstVol extents:(struct HFSPlusExtentDescriptor const *_Nonnull const)extentRecPtr {
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

			totalSize += blockCount * _backingVolume.numberOfBytesPerBlock;
			_extentsPtr[i] = extentRecPtr[i];

			++_numExtents;
		}
		_numExtentsIncludingEmpties += kHFSPlusExtentDensity;

		_totalPhysicalSize = totalSize;
		_blockSize = dstVol.numberOfBytesPerBlock;
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
	u_int32_t const aBlockSizeInBytes = _backingVolume.numberOfBytesPerBlock;
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

	NSAssert([_backingVolume isKindOfClass:[ImpHFSPlusDestinationVolume class]], @"impluse bug: Can't write to destination volumes that aren't HFS+ (yet…)");
	ImpHFSPlusDestinationVolume *_Nonnull const hfsPlusVol = (ImpHFSPlusDestinationVolume *)_backingVolume;

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
		NSInteger bytesWrittenThisTime = [hfsPlusVol writeData:dataNotYetWritten startingFrom:bytesWrittenSoFar toExtent:&_remainderOfCurrentExtent error:outError];
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

		NSInteger bytesWrittenThisTime = [hfsPlusVol writeData:dataToWrite startingFrom:offsetIntoData toExtent:&extentToWrite error:outError];
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

	if (bytesWrittenSoFar >= 0 && (data.length > (NSUInteger)bytesWrittenSoFar) && _currentExtentIndex < _numExtents) {
		if (_remainderOfCurrentExtent.blockCount == 0) {
			_remainderOfCurrentExtent = _extentsPtr[_currentExtentIndex];
		}

		//Write out the remainder of this data without advancing the mark. We'll pad it with zeroes to a full block for this last write, but then leave it in the buffer unpadded so that if another write comes in, we can prepend this data to the next data to overwrite the block.
		[dataNotYetWritten setData:[data subdataWithRange:(NSRange){ bytesWrittenSoFar, data.length - bytesWrittenSoFar }]];
//		NSUInteger const numBytesNotYetWritten = dataNotYetWritten.length;

//		[dataNotYetWritten setLength:_blockSize]; //This should extend rather than truncate, since we're going from a partial block to a full block.
		NSInteger bytesWrittenThisTime = [hfsPlusVol writeData:dataNotYetWritten startingFrom:0 toExtent:&_remainderOfCurrentExtent error:outError];
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
