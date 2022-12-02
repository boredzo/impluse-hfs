//
//  ImpHFSVolume.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-26.
//

#import "ImpHFSVolume.h"

#import "ImpByteOrder.h"
#import "ImpSizeUtilities.h"
#import "ImpExtentSeries.h"
#import "ImpBTreeFile.h"

#import <hfs/hfs_format.h>
enum { kISOStandardBlockSize = 512 };

@implementation ImpHFSVolume
{
	NSMutableData *_bootBlocksData;
	NSData *_mdbData;
	struct HFSMasterDirectoryBlock const *_mdb;
	NSMutableData *_volumeBitmapData;
	CFBitVectorRef _bitVector;
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

	NSData *_Nullable const catalogFileData = [self readDataFromFileDescriptor:readFD extents:_mdb->drCTExtRec error:outError];
	self.catalogBTree = [[ImpBTreeFile alloc] initWithData:catalogFileData];

	return (self.catalogBTree != nil);
}

- (bool)readExtentsOverflowFileFromFileDescriptor:(int const)readFD error:(NSError *_Nullable *_Nonnull const)outError {
	//IM:F says:
	//>All the areas on a volume are of fixed size and location, except for the catalog file and the extents overflow file. These two files can appear anywhere between the volume bitmap and the alternate master directory block (MDB). They can appear in any order and are not necessarily contiguous.
	//So we essentially have to treat the cat file as a file.

	struct HFSExtentDescriptor const *_Nonnull const eoExtDescs = _mdb->drXTExtRec;
	NSNumberFormatter *_Nonnull const fmtr = [NSNumberFormatter new];
	fmtr.numberStyle = NSNumberFormatterDecimalStyle;
	fmtr.hasThousandSeparators = true;
	ImpPrintf(@"Extents overflow extent the first: start block #%@, length %@ blocks", [fmtr stringFromNumber:@(L(eoExtDescs[0].startBlock))], [fmtr stringFromNumber:@(L(eoExtDescs[0].blockCount))]);
	ImpPrintf(@"Extents overflow extent the second: start block #%@, length %@ blocks", [fmtr stringFromNumber:@(L(eoExtDescs[1].startBlock))], [fmtr stringFromNumber:@(L(eoExtDescs[1].blockCount))]);
	ImpPrintf(@"Extents overflow extent the third: start block #%@, length %@ blocks", [fmtr stringFromNumber:@(L(eoExtDescs[2].startBlock))], [fmtr stringFromNumber:@(L(eoExtDescs[2].blockCount))]);

	NSData *_Nullable const extentsFileData = [self readDataFromFileDescriptor:readFD extents:_mdb->drXTExtRec error:outError];
	ImpPrintf(@"Extents file data: %lu bytes", extentsFileData.length);
	return false;
//	self.extentsOverflowBTree = [[ImpBTreeFile alloc] initWithData:extentsFileData];

//	return (self.extentsOverflowBTree != nil);
}

#pragma mark -

///Returns intoData on success; nil on failure. The copy's destination starts offset bytes into the data.
- (NSData *_Nullable) readData:(NSMutableData *_Nonnull const)intoData
	atOffset:(NSUInteger)offset
	fromFileDescriptor:(int const)readFD
	extent:(struct HFSExtentDescriptor const *_Nonnull const)hfsExt
	error:(NSError *_Nullable *_Nonnull const)outError
{
	ImpPrintf(@"Checking whether extent starting at %u is allocated before reading:", L(hfsExt->startBlock));
	int32_t firstUnallocatedBlockNumber = -1;
	for (u_int16_t i = 0; i < L(hfsExt->blockCount); ++i) {
		ImpPrintf(@"- #%u: %@", L(hfsExt->startBlock) + i, CFBitVectorGetBitAtIndex(_bitVector, L(hfsExt->startBlock) + i) ? @"YES" : @"NO!");
		if (! CFBitVectorGetBitAtIndex(_bitVector, L(hfsExt->startBlock) + i)) {
			firstUnallocatedBlockNumber = L(hfsExt->startBlock) + i;
		}
	}
	if (firstUnallocatedBlockNumber > -1) {
		//It's possible that this should be a warning, or that its level of fatality should be adjustable (particularly in situations of data recovery).
		NSError *_Nonnull const readingIntoTheVoidError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Attempt to read block #%u, which is unallocated; this may indicate a bug in this program, or that the volume itself was corrupt (please save a copy of it using bzip2)", @""), firstUnallocatedBlockNumber] }];
		if (outError != NULL) {
			*outError = readingIntoTheVoidError;
		}
		return nil;
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
		return nil;
	}
	@autoreleasepool {
		NSData *_Nonnull const excerpt = [intoData subdataWithRange:(NSRange){ offset, intoData.length - offset }];
		[excerpt writeToURL:[[NSURL fileURLWithPath:@"/tmp" isDirectory:true] URLByAppendingPathComponent:[NSString stringWithFormat:@"hfs+%llu.dat", readStart] isDirectory:false] options:0 error:NULL];
	}
	return intoData;
}

- (NSData *_Nullable) readDataFromFileDescriptor:(int const)readFD
	extent:(struct HFSExtentDescriptor const *_Nonnull const)hfsExt
	error:(NSError *_Nullable *_Nonnull const)outError
{
	NSUInteger const len = L(hfsExt->blockCount) * L(_mdb->drAlBlkSiz);
	NSMutableData *_Nonnull const data = [NSMutableData dataWithLength:len];
	return [self readData:data
		atOffset:0
		fromFileDescriptor:readFD
		extent:hfsExt
		error:outError];
}

- (NSData *_Nullable) readDataFromFileDescriptor:(int const)readFD
	extents:(struct HFSExtentDescriptor const *_Nonnull const)hfsExtRec
	error:(NSError *_Nullable *_Nonnull const)outError
{
	NSUInteger const blockSize = L(_mdb->drAlBlkSiz);
	struct HFSExtentDescriptor const *_Nonnull hfsExt = (struct HFSExtentDescriptor const *_Nonnull)hfsExtRec;
	NSMutableData *_Nonnull const data = [NSMutableData dataWithLength:blockSize * L(hfsExt->blockCount)];
	ImpPrintf(@"Reading first extent with offset %lu", 0UL);
	NSNumberFormatter *_Nonnull const fmtr = [NSNumberFormatter new];
	fmtr.numberStyle = NSNumberFormatterDecimalStyle;
	fmtr.hasThousandSeparators = true;
	ImpPrintf(@"Reading extent the first: start block #%@, length %@ blocks", [fmtr stringFromNumber:@(L(hfsExt->startBlock))], [fmtr stringFromNumber:@(L(hfsExt->blockCount))]);
	NSData *_Nullable const success0 = [self readData:data
		atOffset:0
		fromFileDescriptor:readFD
		extent:hfsExt
		error:outError];
	bool successfullyReadAllNonEmptyExtents = (success0 != NULL);
	if (success0 != NULL && L((++hfsExt)->blockCount) > 0) {
		NSUInteger offset = data.length;
		ImpPrintf(@"Reading second extent with offset %lu", offset);
		ImpPrintf(@"Reading extent the second: start block #%@, length %@ blocks", [fmtr stringFromNumber:@(L(hfsExt->startBlock))], [fmtr stringFromNumber:@(L(hfsExt->blockCount))]);
		[data increaseLengthBy:blockSize * L(hfsExt->blockCount)];
		NSData *_Nullable const success1 = [self readData:data
			atOffset:offset
			fromFileDescriptor:readFD
			extent:hfsExt
			error:outError];
		successfullyReadAllNonEmptyExtents = (success0 != NULL) && (success1 != NULL);
		if (success1 != NULL && L((++hfsExt)->blockCount) > 0) {
			offset = data.length;
			ImpPrintf(@"Reading third extent with offset %lu", offset);
			ImpPrintf(@"Reading extent the third: start block #%@, length %@ blocks", [fmtr stringFromNumber:@(L(hfsExt->startBlock))], [fmtr stringFromNumber:@(L(hfsExt->blockCount))]);
			[data increaseLengthBy:blockSize * L(hfsExt->blockCount)];
			NSData *_Nullable const success2 = [self readData:data
				atOffset:offset
				fromFileDescriptor:readFD
				extent:hfsExt
				error:outError];
			successfullyReadAllNonEmptyExtents = (success0 != NULL) && (success1 != NULL) && (success2 != NULL);
		}
	}
	return successfullyReadAllNonEmptyExtents ? success0 : nil;
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
	return CFAutorelease(CFStringCreateWithPascalStringNoCopy(kCFAllocatorDefault, _mdb->drVN, kCFStringEncodingMacRoman, kCFAllocatorNull));
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

@end
