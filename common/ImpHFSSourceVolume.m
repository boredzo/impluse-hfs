//
//  ImpHFSSourceVolume.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2024-03-07.
//

#import "ImpHFSSourceVolume.h"

#import "ImpSizeUtilities.h"

#import "ImpBTreeFile.h"

@implementation ImpHFSSourceVolume
{
	NSData *_mdbData;
	struct HFSMasterDirectoryBlock const *_mdb;
}

#pragma mark Property accessors

- (void) peekAtHFSVolumeHeader:(void (^_Nonnull const)(struct HFSMasterDirectoryBlock const *_Nonnull const mdbPtr NS_NOESCAPE))block {
	block(_mdb);
}

- (off_t) offsetOfFirstAllocationBlock {
	return L(_mdb->drAlBlSt) * kISOStandardBlockSize;
}

- (NSString *_Nonnull) volumeName {
	//TODO: Use ImpTextEncodingConverter and connect this to any user-facing configuration options for HFS text encoding.
	return CFAutorelease(CFStringCreateWithPascalStringNoCopy(kCFAllocatorDefault, _mdb->drVN, kCFStringEncodingMacRoman, kCFAllocatorNull));
}
- (u_int32_t) firstPhysicalBlockOfFirstAllocationBlock {
	return L(_mdb->drAlBlSt);
}
- (HFSCatalogNodeID) nextCatalogNodeID {
	return L(_mdb->drNxtCNID);
}
- (u_int32_t) numberOfBytesPerBlock {
	return L(_mdb->drAlBlkSiz);
}
- (NSUInteger) numberOfBlocksTotal {
	return L(_mdb->drNmAlBlks);
}
- (NSUInteger) numberOfBlocksUsed {
	return self.numberOfBlocksTotal - self.numberOfBlocksFree;
}
- (NSUInteger) numberOfBlocksFree {
	return L(_mdb->drFreeBks);
}
- (NSUInteger) numberOfFiles {
	return L(_mdb->drFilCnt);
}
- (NSUInteger) numberOfFolders {
	return L(_mdb->drDirCnt);
}

- (NSUInteger) catalogSizeInBytes {
	return L(_mdb->drCTFlSize);
}
- (NSUInteger) extentsOverflowSizeInBytes {
	return L(_mdb->drXTFlSize);
}

#pragma mark Loading the volume structures

- (bool) readVolumeHeaderFromFileDescriptor:(int const)readFD error:(NSError *_Nullable *_Nonnull const)outError {
	//The volume header occupies the first sizeof(HFSMasterDirectoryBlock) bytes of one 512-byte block.
	NSMutableData *_Nonnull const mdbData = [NSMutableData dataWithLength:ImpNextMultipleOfSize(sizeof(HFSMasterDirectoryBlock), kISOStandardBlockSize)];
	ssize_t const amtRead = pread(readFD, mdbData.mutableBytes, mdbData.length, _startOffsetInBytes + kISOStandardBlockSize * 2);
	if (amtRead < 0) {
		NSError *_Nonnull const readError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: @"Error reading source volume HFS header" }];
		if (outError != NULL) *outError = readError;
		return false;
	} else if ((NSUInteger)amtRead < mdbData.length) {
		NSError *_Nonnull const underrunError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:@{ NSLocalizedDescriptionKey: @"Unexpected end of file reading source volume HFS header — are you sure this is an HFS volume?" }];
		if (outError != NULL) *outError = underrunError;
		return false;
	}

	_mdbData = mdbData;
	_mdb = mdbData.bytes;

	if (L(_mdb->drSigWord) != kHFSSigWord) {
		NSError *_Nonnull const thisIsNotHFSError = [NSError errorWithDomain:NSOSStatusErrorDomain code:noMacDskErr userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Unrecognized signature 0x%04x (expected 0x%04x) in what should have been the master directory block/volume header. This doesn't look like an HFS volume.", L(_mdb->drSigWord), kHFSSigWord ] }];
		if (outError != NULL) *outError = thisIsNotHFSError;
		return false;
	}

	return true;
}

- (bool)readAllocationBitmapFromFileDescriptor:(int const)readFD tapURL:(NSURL *_Nullable const)tapURL error:(NSError *_Nullable *_Nonnull const)outError {
	//Volume bitmap immediately follows MDB. We could look at drVBMSt, but it should always be 3.
	//Volume bitmap *size* is drNmAlBlks bits, or (drNmAlBlks / 8) bytes.
	size_t const vbmMinimumNumBytes = ImpNextMultipleOfSize(L(_mdb->drNmAlBlks), 8) / 8;
	off_t const vbmStartPos = (
		_bootBlocksData.length
		+
		_mdbData.length
	);
	off_t vbmEndPos = (
		vbmStartPos
		+
		//Note: Not drAlBlkSiz, per TN1150—the VBM is specifically always based on 512-byte blocks.
		ImpNextMultipleOfSize(vbmMinimumNumBytes, kISOStandardBlockSize)
	);
	off_t const vbmFinalNumBytes = vbmEndPos - vbmStartPos;
#if ImpHFS_DEBUG_LOGGING
	ImpPrintf(@"VBM minimum size in bytes is number of blocks %u / 8 = 0x%zx", (unsigned)L(_mdb->drNmAlBlks), vbmMinimumNumBytes);
	ImpPrintf(@"VBM starts at 0x%llx, runs for 0x%llx (%.1f blocks), ends at 0x%llx", vbmStartPos, vbmFinalNumBytes, vbmFinalNumBytes / (double)L(_mdb->drAlBlkSiz), vbmEndPos);
#endif

	NSMutableData *_Nonnull const volumeBitmap = [NSMutableData dataWithLength:vbmFinalNumBytes];
#if ImpHFS_DEBUG_LOGGING
	ImpPrintf(@"Reading %zu (0x%zx) bytes (%zu blocks) of VBM starting from offset 0x%llx bytes", volumeBitmap.length, volumeBitmap.length, volumeBitmap.length / kISOStandardBlockSize, lseek(readFD, 0, SEEK_CUR));
#endif
	ssize_t const amtRead = pread(readFD, volumeBitmap.mutableBytes, volumeBitmap.length, _startOffsetInBytes + kISOStandardBlockSize * 3);
	if (amtRead < 0) {
		NSError *_Nonnull const readError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: @"Error reading source volume allocation bitmap" }];
		if (outError != NULL) *outError = readError;
		return false;
	} else if ((NSUInteger)amtRead < volumeBitmap.length) {
		NSError *_Nonnull const underrunError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:@{ NSLocalizedDescriptionKey: @"Unexpected end of file reading source volume allocation bitmap — are you sure this is an HFS volume?" }];
		if (outError != NULL) *outError = underrunError;
		return false;
	}
	if (tapURL != nil) [volumeBitmap writeToURL:tapURL options:0 error:NULL];

	[self setAllocationBitmapData:volumeBitmap numberOfBits:L(_mdb->drNmAlBlks)];

	return true;
}

- (bool)readCatalogFileFromFileDescriptor:(int const)readFD tapURL:(NSURL *_Nullable const)tapURL error:(NSError *_Nullable *_Nonnull const)outError {
	//IM:F says:
	//>All the areas on a volume are of fixed size and location, except for the catalog file and the extents overflow file. These two files can appear anywhere between the volume bitmap and the alternate master directory block (MDB). They can appear in any order and are not necessarily contiguous.
	//So we essentially have to treat the cat file as a file.
	//TODO: We may also need to load further extents from the extents overflow file, if the catalog is particularly fragmented. Only using the extent record in the volume header may lead to only having part of the catalog.
	struct HFSExtentDescriptor const *_Nonnull const catExtDescs = _mdb->drCTExtRec;
	u_int64_t const catFileLen = L(_mdb->drCTFlSize);
	NSMutableData *_Nonnull const catalogFileData = [NSMutableData dataWithCapacity:ImpNumberOfBlocksInHFSExtentRecord(catExtDescs) * L(_mdb->drAlBlkSiz)];
	__block u_int32_t numExtents = 0;
	[self forEachExtentInFileWithID:kHFSCatalogFileID
							   fork:ImpForkTypeData
				  forkLogicalLength:catFileLen
		  startingWithExtentsRecord:catExtDescs
			  readDataOrReturnError:outError
							  block:^bool(NSData *const  _Nonnull fileData, const u_int64_t logicalLength) {
		[catalogFileData appendData:fileData];
		++numExtents;
		return true;
	}];
	if (tapURL != nil) [catalogFileData writeToURL:tapURL options:0 error:NULL];

	bool const successfullyReadCatalog = catalogFileData != nil && catalogFileData.length > 0;
	if (successfullyReadCatalog) {
		self.catalogBTree = [[ImpBTreeFile alloc] initWithVersion:ImpBTreeVersionHFSCatalog data:catalogFileData];
		if (self.catalogBTree == nil) {
			NSError *_Nonnull const noCatalogFileError = [NSError errorWithDomain:NSOSStatusErrorDomain code:badMDBErr userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedString(@"Catalog file was invalid, corrupt, or not where the volume header said it would be", @"") }];
			if (outError != NULL) {
				*outError = noCatalogFileError;
			}
		}
	}
//	ImpPrintf(@"Catalog file is using %lu nodes out of an allocated %lu (%.2f%% utilization)", self.catalogBTree.numberOfLiveNodes, self.catalogBTree.numberOfPotentialNodes, self.catalogBTree.numberOfPotentialNodes > 0 ? (self.catalogBTree.numberOfLiveNodes / (double)self.catalogBTree.numberOfPotentialNodes) * 100.0 : 1.0);

	return successfullyReadCatalog;
}

- (bool)readExtentsOverflowFileFromFileDescriptor:(int const)readFD tapURL:(NSURL *_Nullable const)tapURL error:(NSError *_Nullable *_Nonnull const)outError {
	//IM:F says:
	//>All the areas on a volume are of fixed size and location, except for the catalog file and the extents overflow file. These two files can appear anywhere between the volume bitmap and the alternate master directory block (MDB). They can appear in any order and are not necessarily contiguous.
	//So we essentially have to treat the extents overflow file as a file.

	struct HFSExtentDescriptor const *_Nonnull const eoExtDescs = _mdb->drXTExtRec;
	NSData *_Nullable const extentsFileData = [self readDataFromFileDescriptor:readFD logicalLength:L(_mdb->drXTFlSize) extents:eoExtDescs numExtents:kHFSExtentDensity error:outError];
//	ImpPrintf(@"Extents file logical length from MDB: 0x%x bytes (must be at least %lu a-blocks)", L(_mdb->drXTFlSize), ImpCeilingDivide(extentsFileData.length, L(_mdb->drAlBlkSiz)));
//	ImpPrintf(@"Extents file data: 0x%lx bytes (enough to fill %lu a-blocks)", extentsFileData.length, ImpCeilingDivide(extentsFileData.length, L(_mdb->drAlBlkSiz)));
	if (tapURL != nil) [extentsFileData writeToURL:tapURL options:0 error:NULL];

	if (extentsFileData != nil) {
		self.extentsOverflowBTree = [[ImpBTreeFile alloc] initWithVersion:ImpBTreeVersionHFSExtentsOverflow data:extentsFileData];
		if (self.extentsOverflowBTree == nil) {
			NSError *_Nonnull const noExtentsFileError = [NSError errorWithDomain:NSOSStatusErrorDomain code:badMDBErr userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedString(@"Extents overflow file was invalid, corrupt, or not where the volume header said it would be", @"") }];
			if (outError != NULL) {
				*outError = noExtentsFileError;
			}
		}
	}
//	ImpPrintf(@"Extents file is using %lu nodes out of an allocated %lu (%.2f%% utilization)", self.extentsOverflowBTree.numberOfLiveNodes, self.extentsOverflowBTree.numberOfPotentialNodes, self.extentsOverflowBTree.numberOfPotentialNodes > 0 ? (self.extentsOverflowBTree.numberOfLiveNodes / (double)self.extentsOverflowBTree.numberOfPotentialNodes) * 100.0 : 1.0);

	return (self.extentsOverflowBTree != nil);
}

#pragma mark Orphaned block checking

- (void) findExtentsThatAreAllocatedButAreNotReferencedInTheBTrees:(void (^_Nonnull const)(NSRange))block {
	CFMutableBitVectorRef _Nonnull const orphanedBlocks = CFBitVectorCreateMutableCopy(kCFAllocatorDefault, CFBitVectorGetCount(_bitVector), _bitVector);

	NSUInteger const blockSize = self.numberOfBytesPerBlock;
	u_int64_t (^_Nonnull const markOffBits)(struct HFSExtentDescriptor const *_Nonnull const oneExtent, u_int64_t logicalBytesRemaining) = ^u_int64_t(struct HFSExtentDescriptor const *_Nonnull const oneExtent, u_int64_t logicalBytesRemaining) {
		CFRange const range = { L(oneExtent->startBlock), L(oneExtent->blockCount) };
		CFBitVectorSetBits(orphanedBlocks, range, 0);
		return range.length * blockSize;
	};

	//Mark off bits as used.
	[self.catalogBTree forEachItemInHFSCatalog:nil
		file:^bool(struct HFSCatalogKey const *_Nonnull const keyPtr, struct HFSCatalogFile const *_Nonnull const fileRec) {
			struct HFSExtentDescriptor const *_Nonnull const dataExtents = fileRec->dataExtents;
			[self forEachExtentInFileWithID:L(fileRec->fileID)
				fork:ImpForkTypeData
				forkLogicalLength:L(fileRec->dataLogicalSize)
				startingWithExtentsRecord:dataExtents
				block:markOffBits];
			struct HFSExtentDescriptor const *_Nonnull const rsrcExtents = fileRec->rsrcExtents;
			[self forEachExtentInFileWithID:L(fileRec->fileID)
				fork:ImpForkTypeResource
				forkLogicalLength:L(fileRec->rsrcLogicalSize)
				startingWithExtentsRecord:rsrcExtents
				block:markOffBits];
			return true;
		}
		folder:nil
	];
	//The catalog and extents overflow files themselves occupy extents, so mark those off as well.
	[self forEachExtentInFileWithID:kHFSCatalogFileID
		fork:ImpForkTypeData
		forkLogicalLength:self.catalogSizeInBytes
		startingWithExtentsRecord:_mdb->drCTExtRec
		block:markOffBits];
	[self forEachExtentInFileWithID:kHFSExtentsFileID
		fork:ImpForkTypeData
		forkLogicalLength:self.extentsOverflowSizeInBytes
		startingWithExtentsRecord:_mdb->drXTExtRec
		block:markOffBits];

	[self findExtents:block inBitVector:orphanedBlocks];

	CFRelease(orphanedBlocks);
}

#pragma mark Reading fork contents

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
