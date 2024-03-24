//
//  ImpHFSPlusSourceVolume.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2024-03-08.
//

#import "ImpHFSPlusSourceVolume.h"

#import "ImpSizeUtilities.h"
#import "NSData+ImpSubdata.h"

#import "ImpTextEncodingConverter.h"
#import "ImpBTreeTypes.h"
#import "ImpBTreeFile.h"

@implementation ImpHFSPlusSourceVolume
{
	NSMutableData *_preamble; //Boot blocks + volume header = 1.5 K
	struct HFSPlusVolumeHeader *_vh;
	CFMutableBitVectorRef _allocationsBitmap;
	bool _hasVolumeHeader;
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

- (off_t) offsetOfFirstAllocationBlock {
	return 0;
}
- (HFSCatalogNodeID) nextCatalogNodeID {
	return L(_vh->nextCatalogID);
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

#pragma mark Block allocation

- (bool) isBlockAllocated:(u_int32_t const)blockNumber {
	if (_allocationsBitmap != nil) {
		return CFBitVectorGetBitAtIndex(_allocationsBitmap, blockNumber);
	} else {
		//We're reading the allocations bitmap. Just claim any block we're reading for it is allocated.
		return true;
	}
}

#pragma mark Reading blocks

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

//TODO: This is pretty much copied wholesale from ImpHFSSourceVolume. It would be nice to de-dup the code somehow…
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

@end
