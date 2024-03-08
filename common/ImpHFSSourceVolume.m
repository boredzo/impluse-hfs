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
- (NSUInteger) numberOfBytesPerBlock {
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

- (bool)readAllocationBitmapFromFileDescriptor:(int const)readFD error:(NSError *_Nullable *_Nonnull const)outError {
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

	[self setAllocationBitmapData:volumeBitmap numberOfBits:L(_mdb->drNmAlBlks)];

	return true;
}

- (bool)readCatalogFileFromFileDescriptor:(int const)readFD error:(NSError *_Nullable *_Nonnull const)outError {
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

- (bool)readExtentsOverflowFileFromFileDescriptor:(int const)readFD error:(NSError *_Nullable *_Nonnull const)outError {
	//IM:F says:
	//>All the areas on a volume are of fixed size and location, except for the catalog file and the extents overflow file. These two files can appear anywhere between the volume bitmap and the alternate master directory block (MDB). They can appear in any order and are not necessarily contiguous.
	//So we essentially have to treat the extents overflow file as a file.

	struct HFSExtentDescriptor const *_Nonnull const eoExtDescs = _mdb->drXTExtRec;
	NSData *_Nullable const extentsFileData = [self readDataFromFileDescriptor:readFD logicalLength:L(_mdb->drXTFlSize) extents:eoExtDescs numExtents:kHFSExtentDensity error:outError];
//	ImpPrintf(@"Extents file logical length from MDB: 0x%x bytes (must be at least %lu a-blocks)", L(_mdb->drXTFlSize), ImpCeilingDivide(extentsFileData.length, L(_mdb->drAlBlkSiz)));
//	ImpPrintf(@"Extents file data: 0x%lx bytes (enough to fill %lu a-blocks)", extentsFileData.length, ImpCeilingDivide(extentsFileData.length, L(_mdb->drAlBlkSiz)));

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

@end
