//
//  ImpHFSVolume.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-26.
//

#import "ImpHFSVolume.h"

#import "ImpByteOrder.h"
#import "ImpSizeUtilities.h"
#import "ImpForkUtilities.h"
#import "NSData+ImpSubdata.h"
#import "ImpTextEncodingConverter.h"
#import "ImpExtentSeries.h"
#import "ImpBTreeFile.h"

#import <hfs/hfs_format.h>

@interface ImpHFSVolume ()

@property(readwrite, nonnull, strong) ImpTextEncodingConverter *textEncodingConverter;

@end

@implementation ImpHFSVolume
{
	NSMutableData *_bootBlocksData;
	NSData *_mdbData;
	struct HFSMasterDirectoryBlock const *_mdb;
	NSMutableData *_volumeBitmapData;
	CFBitVectorRef _bitVector;
}

- (instancetype _Nonnull) initWithFileDescriptor:(int const)readFD textEncoding:(TextEncoding const)hfsTextEncoding {
	if ((self = [super init])) {
		_fileDescriptor = readFD;
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
	ssize_t const amtRead = read(readFD, _bootBlocksData.mutableBytes, _bootBlocksData.length);
	if (amtRead < _bootBlocksData.length) {
		NSError *_Nonnull const underrunError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:@{ NSLocalizedDescriptionKey: @"Unexpected end of file reading source volume boot blocks — are you sure this is an HFS volume?" }];
		if (outError != NULL) *outError = underrunError;
		return false;
	}
	//We don't do anything with the boot blocks other than write 'em out verbatim to the HFS+ volume, but that comes later.
	return true;
}

- (bool) readVolumeHeaderFromFileDescriptor:(int const)readFD error:(NSError *_Nullable *_Nonnull const)outError {
	//The volume header occupies the first sizeof(HFSMasterDirectoryBlock) bytes of one 512-byte block.
	NSMutableData *_Nonnull const mdbData = [NSMutableData dataWithLength:ImpNextMultipleOfSize(sizeof(HFSMasterDirectoryBlock), kISOStandardBlockSize)];
	ssize_t const amtRead = read(readFD, mdbData.mutableBytes, mdbData.length);
	if (amtRead < mdbData.length) {
		NSError *_Nonnull const underrunError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:@{ NSLocalizedDescriptionKey: @"Unexpected end of file reading source volume HFS header — are you sure this is an HFS volume?" }];
		if (outError != NULL) *outError = underrunError;
		return false;
	}

	_mdbData = mdbData;
	_mdb = mdbData.bytes;

	if (L(_mdb->drSigWord) != kHFSSigWord) {
		NSError *_Nonnull const thisIsNotHFSError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Unrecognized signature 0x%04x (expected 0x%04x) in what should have been the master directory block/volume header. This doesn't look like an HFS volume.", L(_mdb->drSigWord), kHFSSigWord ] }];
		if (outError != NULL) *outError = thisIsNotHFSError;
		return false;
	}

	return true;
}
- (bool)readAllocationBitmapFromFileDescriptor:(int const)readFD error:(NSError *_Nullable *_Nonnull const)outError {
	//Volume bitmap immediately follows MDB. We could look at drVBMSt, but it should always be 3.
	//Volume bitmap *size* is drNmAlBlks bits, or (drNmAlBlks / 8) bytes.
	size_t const vbmMinimumNumBytes = ImpNextMultipleOfSize(L(_mdb->drNmAlBlks), 8) / 8;
	ImpPrintf(@"VBM minimum size in bytes is number of blocks %u / 8 = 0x%zx", (unsigned)L(_mdb->drNmAlBlks), vbmMinimumNumBytes);
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
	ImpPrintf(@"Allocation block size is 0x%llx (0x200 * %.1f)", L(_mdb->drAlBlkSiz), L(_mdb->drAlBlkSiz) / 512.0);
	ImpPrintf(@"Clump size is 0x%llx (0x200 * %.1f; ABS * %.1f)", L(_mdb->drClpSiz), L(_mdb->drClpSiz) / 512.0, L(_mdb->drClpSiz) / (double)L(_mdb->drAlBlkSiz));
	ImpPrintf(@"VBM starts at 0x%llx, runs for 0x%llx (%.1f blocks), ends at 0x%llx", vbmStartPos, vbmFinalNumBytes, vbmFinalNumBytes / (double)L(_mdb->drAlBlkSiz), vbmEndPos);
	ImpPrintf(@"First allocation block: 0x%llx", L(_mdb->drAlBlSt) * 0x200);

	NSMutableData *_Nonnull const volumeBitmap = [NSMutableData dataWithLength:vbmFinalNumBytes];
	ImpPrintf(@"Reading %zu (0x%zx) bytes (%zu blocks) of VBM starting from offset %lld bytes", volumeBitmap.length, volumeBitmap.length, volumeBitmap.length / kISOStandardBlockSize, lseek(readFD, 0, SEEK_CUR));
	ssize_t const amtRead = read(readFD, volumeBitmap.mutableBytes, volumeBitmap.length);
	if (amtRead < volumeBitmap.length) {
		NSError *_Nonnull const underrunError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:@{ NSLocalizedDescriptionKey: @"Unexpected end of file reading source volume allocation bitmap — are you sure this is an HFS volume?" }];
		if (outError != NULL) *outError = underrunError;
		return false;
	}

	_volumeBitmapData = volumeBitmap;
	_bitVector = CFBitVectorCreate(kCFAllocatorDefault, _volumeBitmapData.bytes, L(_mdb->drNmAlBlks));

	return true;
}

- (bool)readCatalogFileFromFileDescriptor:(int const)readFD error:(NSError *_Nullable *_Nonnull const)outError {
	//IM:F says:
	//>All the areas on a volume are of fixed size and location, except for the catalog file and the extents overflow file. These two files can appear anywhere between the volume bitmap and the alternate master directory block (MDB). They can appear in any order and are not necessarily contiguous.
	//So we essentially have to treat the cat file as a file.
	//TODO: We may also need to load further extents from the extents overflow file, if the catalog is particularly fragmented. Only using the extent record in the volume header may lead to only having part of the catalog.

	struct HFSExtentDescriptor const *_Nonnull const catExtDescs = _mdb->drCTExtRec;
	NSNumberFormatter *_Nonnull const fmtr = [NSNumberFormatter new];
	fmtr.numberStyle = NSNumberFormatterDecimalStyle;
	fmtr.hasThousandSeparators = true;
	ImpPrintf(@"Catalog extent the first: start block #%@, length %@ blocks", [fmtr stringFromNumber:@(L(catExtDescs[0].startBlock))], [fmtr stringFromNumber:@(L(catExtDescs[0].blockCount))]);
	ImpPrintf(@"Catalog extent the second: start block #%@, length %@ blocks", [fmtr stringFromNumber:@(L(catExtDescs[1].startBlock))], [fmtr stringFromNumber:@(L(catExtDescs[1].blockCount))]);
	ImpPrintf(@"Catalog extent the third: start block #%@, length %@ blocks", [fmtr stringFromNumber:@(L(catExtDescs[2].startBlock))], [fmtr stringFromNumber:@(L(catExtDescs[2].blockCount))]);

	NSData *_Nullable const catalogFileData = [self readDataFromFileDescriptor:readFD extents:_mdb->drCTExtRec numExtents:kHFSExtentDensity error:outError];
	self.catalogBTree = [[ImpBTreeFile alloc] initWithData:catalogFileData];

	return (self.catalogBTree != nil);
}

- (bool)readExtentsOverflowFileFromFileDescriptor:(int const)readFD error:(NSError *_Nullable *_Nonnull const)outError {
	//IM:F says:
	//>All the areas on a volume are of fixed size and location, except for the catalog file and the extents overflow file. These two files can appear anywhere between the volume bitmap and the alternate master directory block (MDB). They can appear in any order and are not necessarily contiguous.
	//So we essentially have to treat the extents overflow file as a file.

	struct HFSExtentDescriptor const *_Nonnull const eoExtDescs = _mdb->drXTExtRec;
	NSNumberFormatter *_Nonnull const fmtr = [NSNumberFormatter new];
	fmtr.numberStyle = NSNumberFormatterDecimalStyle;
	fmtr.hasThousandSeparators = true;
	ImpPrintf(@"Extents overflow extent the first: start block #%@, length %@ blocks", [fmtr stringFromNumber:@(L(eoExtDescs[0].startBlock))], [fmtr stringFromNumber:@(L(eoExtDescs[0].blockCount))]);
	ImpPrintf(@"Extents overflow extent the second: start block #%@, length %@ blocks", [fmtr stringFromNumber:@(L(eoExtDescs[1].startBlock))], [fmtr stringFromNumber:@(L(eoExtDescs[1].blockCount))]);
	ImpPrintf(@"Extents overflow extent the third: start block #%@, length %@ blocks", [fmtr stringFromNumber:@(L(eoExtDescs[2].startBlock))], [fmtr stringFromNumber:@(L(eoExtDescs[2].blockCount))]);

	NSData *_Nullable const extentsFileData = [self readDataFromFileDescriptor:readFD extents:_mdb->drXTExtRec numExtents:kHFSExtentDensity error:outError];
	ImpPrintf(@"Extents file data: %lu bytes", extentsFileData.length);

	self.extentsOverflowBTree = [[ImpBTreeFile alloc] initWithData:extentsFileData];

	return (self.extentsOverflowBTree != nil);
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
	);
}

#pragma mark -

///Returns intoData on success; nil on failure. The copy's destination starts offset bytes into the data.
- (bool) readIntoData:(NSMutableData *_Nonnull const)intoData
	atOffset:(NSUInteger)offset
	fromFileDescriptor:(int const)readFD
	extent:(struct HFSExtentDescriptor const *_Nonnull const)hfsExt
	actualAmountRead:(u_int64_t *_Nonnull const)outAmtRead
	error:(NSError *_Nullable *_Nonnull const)outError
{
	int32_t firstUnallocatedBlockNumber = -1;
	//TODO: Optimize using CFBitVectorGetCountOfBit (start range at startBlock, check returned count >= blockCount)
	for (u_int16_t i = 0; i < L(hfsExt->blockCount); ++i) {
//		ImpPrintf(@"- #%u: %@", L(hfsExt->startBlock) + i, CFBitVectorGetBitAtIndex(_bitVector, L(hfsExt->startBlock) + i) ? @"YES" : @"NO!");
		if (! CFBitVectorGetBitAtIndex(_bitVector, L(hfsExt->startBlock) + i)) {
			firstUnallocatedBlockNumber = L(hfsExt->startBlock) + i;
		}
	}
	ImpPrintf(@"Extent starting at %u is fully allocated before reading: %@", L(hfsExt->startBlock), (firstUnallocatedBlockNumber < 0) ? @"YES" : @"NO");
	if (firstUnallocatedBlockNumber > -1) {
		//It's possible that this should be a warning, or that its level of fatality should be adjustable (particularly in situations of data recovery).
		NSError *_Nonnull const readingIntoTheVoidError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Attempt to read block #%u, which is unallocated; this may indicate a bug in this program, or that the volume itself was corrupt (please save a copy of it using bzip2)", @""), firstUnallocatedBlockNumber] }];
		if (outError != NULL) {
			*outError = readingIntoTheVoidError;
		}
		return false;
	}

	off_t const offsetOfFirstAllocationBlock = L(_mdb->drAlBlSt) * kISOStandardBlockSize;
	off_t const readStart = self.volumeStartOffset + offsetOfFirstAllocationBlock + L(hfsExt->startBlock) * L(_mdb->drAlBlkSiz);
	ImpPrintf(@"Reading %lu bytes (%lu blocks) from source volume starting at %llu bytes (extent: [ start #%u, %u blocks ])", intoData.length, intoData.length / L(_mdb->drAlBlkSiz), readStart, L(hfsExt->startBlock), L(hfsExt->blockCount));
	ssize_t const amtRead = pread(readFD, intoData.mutableBytes + offset, intoData.length - offset, readStart);
	if (amtRead < 0) {
		NSError *_Nonnull const readFailedError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to read data from extent { start #%u, %u blocks }", (unsigned)L(hfsExt->startBlock), (unsigned)L(hfsExt->blockCount) ] }];
		if (outError != NULL) {
			*outError = readFailedError;
		}
		return false;
	}

	[intoData withRange:(NSRange){ offset, intoData.length - offset }
		showSubdataToBlock_Imp:^(const void * _Nonnull bytes, NSUInteger length)
	{
		NSData *_Nonnull const excerpt = [[NSData alloc] initWithBytesNoCopy:(void *)bytes length:length freeWhenDone:false];
		[excerpt writeToURL:[[NSURL fileURLWithPath:@"/tmp" isDirectory:true] URLByAppendingPathComponent:[NSString stringWithFormat:@"hfs+%llu.dat", readStart] isDirectory:false] options:0 error:NULL];
	}];

	return true;
}


- (NSData *_Nullable) readDataFromFileDescriptor:(int const)readFD
	extents:(struct HFSExtentDescriptor const *_Nonnull const)extents
	numExtents:(NSUInteger const)numExtents
	error:(NSError *_Nullable *_Nonnull const)outError
{
	NSUInteger const blockSize = L(_mdb->drAlBlkSiz);
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
			extent:&extents[i]
			actualAmountRead:&amtRead
			error:outError];

		totalAmtRead += amtRead;
		successfullyReadAllNonEmptyExtents = successfullyReadAllNonEmptyExtents && success;
	}

	return successfullyReadAllNonEmptyExtents ? [data copy] : nil;
}

- (bool) checkExtentRecord:(HFSExtentRecord const *_Nonnull const)hfsExtRec {
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
- (void) getVolumeHeader:(void *_Nonnull const)outMDB {
	memcpy(outMDB, &_mdb, sizeof(_mdb));
}
- (NSData *_Nonnull) volumeBitmap {
	return _volumeBitmapData;
}

- (NSString *_Nonnull) volumeName {
	//TODO: Use ImpTextEncodingConverter and connect this to any user-facing configuration options for HFS text encoding.
	return CFAutorelease(CFStringCreateWithPascalStringNoCopy(kCFAllocatorDefault, _mdb->drVN, kCFStringEncodingMacRoman, kCFAllocatorNull));
}
- (u_int64_t) totalSizeInBytes {
	return self.numberOfBytesPerBlock * (u_int64_t)self.numberOfBlocksTotal;
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
			ImpPrintf(@"Reading extent starting at block #%u, containing %u blocks", L(hfsExtRec[i].startBlock), L(hfsExtRec[i].blockCount));
			u_int64_t const bytesConsumed = block(&hfsExtRec[i], logicalBytesRemaining);

			if (bytesConsumed == 0) keepIterating = false;

			if (bytesConsumed > logicalBytesRemaining) {
				logicalBytesRemaining = 0;
			} else {
				logicalBytesRemaining -= bytesConsumed;
			}
			if (logicalBytesRemaining == 0) keepIterating = false;
		}
	};

	//First, process the initial extents record from the catalog.
	processOneExtentRecord(initialExtRec, kHFSExtentDensity);

	//Second, if we're not done yet, consult the extents overflow B*-tree for this item.
	if (keepIterating && logicalBytesRemaining > 0) {
		ImpBTreeFile *_Nonnull const extentsFile = self.extentsOverflowBTree;
		[extentsFile searchExtentsOverflowTreeForCatalogNodeID:cnid
			fork:forkType
			firstExtentStart:L(initialExtRec[0].startBlock)
			forEachRecord:^bool(NSData *_Nonnull const recordData)
		{
			struct HFSExtentDescriptor const *_Nonnull const hfsExtRec = recordData.bytes;
			NSUInteger const numExtentDescriptors = recordData.length / sizeof(struct HFSExtentDescriptor);
			processOneExtentRecord(hfsExtRec, numExtentDescriptors);
			return keepIterating;
		}];
	}

	return forkLength - logicalBytesRemaining;
}

///For each extent in the file, call the block with the data contained in that extent and the logical length of it. The logical length will equal the physical length (block size times block count) for extents that aren't the last in the file; for the last extent, the logical length may be shorter than the physical length. For extraction, you should only use the first logicalLength bytes of the file; for conversion to HFS+, you should use the full NSData (copy the full allocation block, including unused data).
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
	u_int64_t const blockSize = L(_mdb->drAlBlkSiz);
	NSMutableData *_Nonnull const data = [NSMutableData dataWithLength:blockSize * L(hfsExtRec[0].blockCount)];
	__weak typeof(self) weakSelf = self;

	totalAmountRead += [self forEachExtentInFileWithID:cnid
		fork:forkType
		forkLogicalLength:forkLength
		startingWithExtentsRecord:hfsExtRec
		block:^u_int64_t(const struct HFSExtentDescriptor *const  _Nonnull oneExtent, u_int64_t logicalBytesRemaining)
	{
		ImpPrintf(@"Reading extent starting at #%u for %u blocks; %llu bytes remain…", L(oneExtent->startBlock), L(oneExtent->blockCount), logicalBytesRemaining);
		u_int64_t const physicalLength = blockSize * L(oneExtent->blockCount);
		u_int64_t const logicalLength = logicalBytesRemaining < physicalLength ? logicalBytesRemaining : physicalLength;
		u_int64_t amtRead = 0;
		[data setLength:logicalLength];
		bool const success = [weakSelf readIntoData:data atOffset:0 fromFileDescriptor:readFD extent:oneExtent actualAmountRead:&amtRead error:&readError];
		if (success) {
			bool const successfullyDelivered = block(data, MAX(amtRead, logicalBytesRemaining));
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
