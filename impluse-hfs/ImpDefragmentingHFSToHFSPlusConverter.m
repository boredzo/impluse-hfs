//
//  ImpDefragmentingHFSToHFSPlusConverter.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-10.
//

#import "ImpDefragmentingHFSToHFSPlusConverter.h"

#import "ImpTextEncodingConverter.h"
#import "ImpSizeUtilities.h"
#import "ImpHFSVolume.h"
#import "ImpHFSPlusVolume.h"
#import "ImpBTreeFile.h"
#import "ImpBTreeNode.h"
#import "ImpBTreeIndexNode.h"
#import "ImpBTreeHeaderNode.h"
#import "ImpMutableBTreeFile.h"

#import <hfs/hfs_format.h>

@implementation ImpDefragmentingHFSToHFSPlusConverter
{
	NSMutableArray <NSData *> *_Nullable _catalogRecords;
	bool _hasBootBlocks, _hasVolumeHeader, _hasAllocationsBitmap, _hasCatalogFile, _hasExtentsOverflowFile, _hasUpdatedExtents;
}

#pragma mark Conversion utilities

- (void) convertHFSVolumeHeader:(struct HFSMasterDirectoryBlock const *_Nonnull const)mdbPtr toHFSPlusVolumeHeader:(struct HFSPlusVolumeHeader *_Nonnull const)vhPtr
{
	[super convertHFSVolumeHeader:mdbPtr toHFSPlusVolumeHeader:vhPtr];

	//Reset some things that don't make sense in a defragmenting conversion, and let them be repopulated elsewhere.
	u_int32_t const blockSize = kISOStandardBlockSize;
	S(vhPtr->blockSize, blockSize);
	u_int32_t const clumpSize = blockSize * 2 * 2;
	S(vhPtr->rsrcClumpSize, clumpSize);
	S(vhPtr->dataClumpSize, clumpSize);

	//To be repopulated by initializing the allocations file.
	S(vhPtr->totalBlocks, 0);
	S(vhPtr->freeBlocks, 0);
	S(vhPtr->nextAllocation, 0);
}

- (void) copyFromHFSExtentsOverflowFile:(ImpBTreeFile *_Nonnull const)sourceTree toHFSPlusExtentsOverflowFile:(ImpMutableBTreeFile *_Nonnull const)destTree {
	//We're going to copy files anew, without regard to where they might have been on the source volume, so any extents in the old extents overflow file have no relevance in the new one. The new one will very likely be empty; if it isn't, any files that do end up in it will be added when those files are copied.

	//At one point I thought we have to create an extents overflow file with an empty leaf node (so that there's a root node). Evidently not: fsck_hfs explicitly flags this as invalid.
#if 0
	ImpBTreeNode *_Nonnull const leafNode = [destTree allocateNewNodeOfKind:kBTLeafNode populate:^(void *_Nonnull bytes, NSUInteger length) {
		struct BTNodeDescriptor *_Nonnull const nodeDesc = bytes;
		S(nodeDesc->height, 1);
	}];
#endif

	u_int32_t const numNodesTotal = (u_int32_t)(destTree.lengthInBytes / destTree.bytesPerNode);
	u_int32_t const numNodesUsed = 1; //The header node.
	[destTree.headerNode reviseHeaderRecord:^(struct BTHeaderRec *_Nonnull const headerRecPtr) {
		S(headerRecPtr->rootNode, 0);
		S(headerRecPtr->treeDepth, 0);
		S(headerRecPtr->firstLeafNode, 0);
		S(headerRecPtr->lastLeafNode, 0);
		S(headerRecPtr->leafRecords, 0);
		S(headerRecPtr->totalNodes, numNodesTotal);
		S(headerRecPtr->freeNodes, (numNodesTotal - numNodesUsed));
		S(headerRecPtr->maxKeyLength, (u_int16_t)kHFSPlusExtentKeyMaximumLength);
	}];
}

#pragma mark Steps

- (bool) step1_convertPreamble_error:(NSError *_Nullable *_Nullable const)outError {
	bool const succeeded = [super step1_convertPreamble_error:outError];
	_hasBootBlocks = _hasVolumeHeader = succeeded;
	return succeeded;
}

- (bool) step2_convertVolume_error:(NSError *_Nullable *_Nullable const)outError {
	NSAssert(_hasVolumeHeader, @"Conversion steps happening out of order! Cannot convert the volume without the volume header.");

	ImpHFSVolume *_Nonnull const srcVol = self.sourceVolume;
	ImpHFSPlusVolume *_Nonnull const dstVol = self.destinationVolume;

	__block struct HFSExtentDescriptor const *_Nonnull catalogFileSourceExtents;
	__block struct HFSExtentDescriptor const *_Nonnull extentsOverflowFileSourceExtents;
	[srcVol peekAtHFSVolumeHeader:^(NS_NOESCAPE const struct HFSMasterDirectoryBlock *const mdbPtr) {
		catalogFileSourceExtents = mdbPtr->drCTExtRec;
		extentsOverflowFileSourceExtents = mdbPtr->drXTExtRec;
	}];

	struct HFSPlusVolumeHeader *_Nonnull const vh = dstVol.mutableVolumeHeaderPointer;
	__block bool hasAnyFiles = false;

	u_int64_t const volumeSizeInBytes = dstVol.sizeInBytes ?: srcVol.totalSizeInBytes;

	u_int32_t const bytesPerSourceABlock = (u_int32_t)srcVol.numberOfBytesPerBlock;

	u_int32_t const bytesPerABlock = L(vh->blockSize);
	u_int32_t const numBlocksInVolume = (u_int32_t)(volumeSizeInBytes / bytesPerABlock);
	[dstVol initializeAllocationBitmapWithBlockSize:bytesPerABlock count:numBlocksInVolume];

	//We do need to create/have an extents overflow file, even if it's empty.
	ImpBTreeFile *_Nonnull const srcExtentsOverflow = srcVol.extentsOverflowBTree;
	ImpMutableBTreeFile *_Nonnull const destExtentsOverflow = [[ImpMutableBTreeFile alloc] initWithVersion:ImpBTreeVersionHFSPlusExtentsOverflow convertTree:srcExtentsOverflow];
	[self copyFromHFSExtentsOverflowFile:srcExtentsOverflow toHFSPlusExtentsOverflowFile:destExtentsOverflow];
	//Since we're not copying over anything from the original extents overflow file, deduct it from the amount of data to be copied.
	[self reportSourceExtentRecordWillNotBeCopied:extentsOverflowFileSourceExtents];

	ImpBTreeFile *_Nonnull const srcCatalog = srcVol.catalogBTree;
	ImpMutableBTreeFile *_Nonnull const destCatalog = [[ImpMutableBTreeFile alloc] initWithVersion:ImpBTreeVersionHFSPlusCatalog convertTree:srcCatalog];
	[self copyFromHFSCatalogFile:srcCatalog toHFSPlusCatalogFile:destCatalog];
	[self reportSourceExtentRecordCopied:catalogFileSourceExtents];

	//Allocate the special files before anything else, so they get placed first on the disk.
	u_int32_t const catFileLength = (u_int32_t)destCatalog.lengthInBytes;
	[dstVol allocateLogicalLength:catFileLength forFork:ImpForkTypeSpecialFileContents populateExtentRecord:vh->catalogFile.extents];
	S(vh->catalogFile.logicalSize, catFileLength);
	S(vh->catalogFile.totalBlocks, L(vh->catalogFile.extents[0].blockCount));
	u_int32_t const extFileLength = (u_int32_t)destExtentsOverflow.lengthInBytes;
	[dstVol allocateLogicalLength:extFileLength forFork:ImpForkTypeSpecialFileContents populateExtentRecord:vh->extentsFile.extents];
	S(vh->extentsFile.logicalSize, extFileLength);
	S(vh->extentsFile.totalBlocks, L(vh->extentsFile.extents[0].blockCount));
//	ImpPrintf(@"Catalog file will be %llu bytes in %u blocks", L(vh->catalogFile.logicalSize), L(vh->catalogFile.totalBlocks));
//	ImpPrintf(@"Extents overflow file will be %llu bytes in %u blocks", L(vh->extentsFile.logicalSize), L(vh->extentsFile.totalBlocks));

	__block bool copiedEverything = true;

	//Copy all the files over.
	[srcCatalog walkLeafNodes:^bool(ImpBTreeNode *const _Nonnull srcLeafNode) {
		__block bool keepGoing = true;
		[srcLeafNode forEachHFSCatalogRecord_file:^(const struct HFSCatalogKey *const  _Nonnull keyPtr, const struct HFSCatalogFile *const _Nonnull fileRec) {
			struct HFSPlusCatalogKey convertedKey;
			[self convertHFSCatalogKey:keyPtr toHFSPlus:&convertedKey];

			struct HFSUniStr255 *_Nonnull const unicodeNamePtr = &convertedKey.nodeName;
			ImpBTreeCursor *_Nullable const cursor = [destCatalog searchCatalogTreeForItemWithParentID:convertedKey.parentID unicodeName:unicodeNamePtr];
			NSAssert(cursor != nil, @"Could not find file “%@” in parent ID %u in the converted catalog, and thus could not copy the file's contents", [srcVol.textEncodingConverter stringFromHFSUniStr255:unicodeNamePtr], L(convertedKey.parentID));
			NSMutableData *_Nonnull const convertedFileRecData = [[cursor payloadData] mutableCopy];
			struct HFSPlusCatalogFile *_Nonnull const convertedFilePtr = convertedFileRecData.mutableBytes;

			hasAnyFiles = true;
			[self deliverProgressUpdateWithOperationDescription:[NSString stringWithFormat:NSLocalizedString(@"Copying file “%@”…", @"Conversion progress message"), [srcVol.textEncodingConverter stringFromHFSUniStr255:unicodeNamePtr]]];

			//Copy the data fork.
			struct HFSExtentDescriptor const *_Nonnull const firstDataExtents = fileRec->dataExtents;
			u_int64_t const dataLogicalLength = L(fileRec->dataLogicalSize);

			u_int64_t bytesNotYetAllocatedForData = [dstVol allocateLogicalLength:dataLogicalLength forFork:ImpForkTypeData populateExtentRecord:convertedFilePtr->dataFork.extents];
			//TODO: Handle bytesNotYetAllocated > 0 (by inserting the fork into the extents overflow file)
			NSAssert(bytesNotYetAllocatedForData == 0, @"Failed to allocate %llu contiguous bytes in destination volume; ended up with %llu left over", dataLogicalLength, bytesNotYetAllocatedForData);

			NSError *_Nullable dataReadError = nil;
			__block NSError *_Nullable dataWriteError = nil;
			ImpVirtualFileHandle *_Nonnull const dataFH = [dstVol fileHandleForWritingToExtents:convertedFilePtr->dataFork.extents];
			__block u_int64_t totalDataBytesWritten = 0;
			__block u_int32_t totalDataBlocksRead = 0;

			[srcVol forEachExtentInFileWithID:L(fileRec->fileID)
				fork:ImpForkTypeData
				forkLogicalLength:dataLogicalLength
				startingWithExtentsRecord:firstDataExtents
				readDataOrReturnError:&dataReadError
				block:^bool(NSData *const  _Nonnull fileData, const u_int64_t logicalLength)
			{
//				ImpPrintf(@"Read file data: %lu physical bytes (%llu length remaining)", fileData.length, logicalLength);
				totalDataBlocksRead += (u_int32_t)(fileData.length / bytesPerSourceABlock);
				NSInteger const bytesWrittenThisTime = [dataFH writeData:fileData error:&dataWriteError];
//				ImpPrintf(@"Wrote file data: %ld bytes", (long)bytesWrittenThisTime);
				if (bytesWrittenThisTime >= 0) {
					totalDataBytesWritten += bytesWrittenThisTime;
//					ImpPrintf(@"Total written so far: %llu bytes", totalDataBytesWritten);
					return true;
				} else {
					copiedEverything = false;
					return false;
				}
			}];
			[dataFH closeFile];

//			ImpPrintf(@"Final tally: Wrote %llu out of %llu bytes", totalDataBytesWritten, dataLogicalLength);
			NSAssert(totalDataBytesWritten == dataLogicalLength, @"Failed to %@ all data fork bytes due to %@: should have written %llu, but actually wrote %llu", dataReadError != nil ? @"read" : dataWriteError != nil ? @"write" : @"copy", dataReadError ?: dataWriteError, dataLogicalLength, totalDataBytesWritten);
			[self reportSourceBlocksCopied:totalDataBlocksRead];

			S(convertedFilePtr->dataFork.logicalSize, totalDataBytesWritten);
			u_int64_t const totalDataBlocks = ImpNumberOfBlocksInHFSPlusExtentRecord(convertedFilePtr->dataFork.extents);
			//TN1150 does not specify what to do if totalBlocks is greater than UINT32_MAX (which it theoretically can be, because the blockCount of each extent is also a u_int32_t and there are eight of them per extent record).
			S(convertedFilePtr->dataFork.totalBlocks, totalDataBlocks > UINT32_MAX ? UINT32_MAX : (u_int32_t)totalDataBlocks);
			//Note: clumpSize should be left 0 per TN1150.

			//Copy the resource fork.
			struct HFSExtentDescriptor const *_Nonnull const firstRsrcExtents = fileRec->rsrcExtents;
			u_int64_t const rsrcLogicalLength = L(fileRec->rsrcLogicalSize);

			u_int64_t bytesNotYetAllocatedForRsrc = [dstVol allocateLogicalLength:rsrcLogicalLength forFork:ImpForkTypeResource populateExtentRecord:convertedFilePtr->resourceFork.extents];
			//TODO: Handle bytesNotYetAllocated > 0 (by inserting the fork into the extents overflow file)
			NSAssert(bytesNotYetAllocatedForRsrc == 0, @"Failed to allocate %llu contiguous bytes in destination volume; ended up with %llu left over", rsrcLogicalLength, bytesNotYetAllocatedForRsrc);

			NSError *_Nullable rsrcReadError = nil;
			__block NSError *_Nullable rsrcWriteError = nil;
			ImpVirtualFileHandle *_Nonnull const rsrcFH = [dstVol fileHandleForWritingToExtents:convertedFilePtr->resourceFork.extents];
			__block u_int64_t totalRsrcBytesWritten = 0;
			__block u_int32_t totalRsrcBlocksRead = 0;

			[srcVol forEachExtentInFileWithID:L(fileRec->fileID)
				fork:ImpForkTypeResource
				forkLogicalLength:rsrcLogicalLength
				startingWithExtentsRecord:firstRsrcExtents
				readDataOrReturnError:&rsrcReadError
				block:^bool(NSData *const  _Nonnull fileData, const u_int64_t logicalLength)
			{
				totalRsrcBlocksRead += (u_int32_t)(fileData.length / bytesPerSourceABlock);
				NSInteger const bytesWrittenThisTime = [rsrcFH writeData:fileData error:&rsrcWriteError];
				if (bytesWrittenThisTime >= 0) {
					totalRsrcBytesWritten += bytesWrittenThisTime;
					return true;
				} else {
					copiedEverything = false;
					return false;
				}
			}];
			[rsrcFH closeFile];

			NSAssert(totalRsrcBytesWritten == rsrcLogicalLength, @"Failed to write all resource fork bytes for unknown reasons: should have written %llu, but actually wrote %llu", rsrcLogicalLength, totalRsrcBytesWritten);
			[self reportSourceBlocksCopied:totalRsrcBlocksRead];

			S(convertedFilePtr->resourceFork.logicalSize, totalRsrcBytesWritten);
			u_int64_t const totalRsrcBlocks = ImpNumberOfBlocksInHFSPlusExtentRecord(convertedFilePtr->resourceFork.extents);
			//TN1150 does not specify what to do if totalBlocks is greater than UINT32_MAX (which it theoretically can be, because the blockCount of each extent is also a u_int32_t and there are eight of them per extent record).
			S(convertedFilePtr->resourceFork.totalBlocks, totalRsrcBlocks > UINT32_MAX ? UINT32_MAX : (u_int32_t)totalRsrcBlocks);
			//Note: clumpSize should be left 0 per TN1150.

			cursor.payloadData = convertedFileRecData;

			keepGoing = true;
		}
			folder:nil
			thread:nil
		];
		return keepGoing;
	}];

	[self deliverProgressUpdateWithOperationDescription:NSLocalizedString(@"Updating catalog…", @"Conversion progress message")];

	//Lastly (now that the catalog file has been populated with files' real extents), write the catalog and extents overflow files.
	//TODO: Should this be a separate step in the superclass? Maybe make the ImpMutableBTreeFiles properties?
	__block bool wroteCatalog = false;
	__block NSError *_Nullable catWriteError = nil;
	[destCatalog serializeToData:^(NSData *const  _Nonnull data) {
		ImpVirtualFileHandle *_Nonnull const catFH = [dstVol fileHandleForWritingToExtents:vh->catalogFile.extents];
		wroteCatalog = [catFH writeData:data error:&catWriteError];
		[catFH closeFile];
	}];

	__block bool wroteExtentsOverflow = false;
	__block NSError *_Nullable extWriteError = nil;
	[destExtentsOverflow serializeToData:^(NSData *const  _Nonnull data) {
		ImpVirtualFileHandle *_Nonnull const extFH = [dstVol fileHandleForWritingToExtents:vh->extentsFile.extents];
		wroteExtentsOverflow = [extFH writeData:data error:&extWriteError];
		[extFH closeFile];
	}];

	S(vh->totalBlocks, numBlocksInVolume);
	S(vh->freeBlocks, [dstVol numberOfBlocksFreeAccordingToWorkingBitmap]);
	if (! hasAnyFiles) {
		//The encodings bitmap must have 1 bit set for each encoding used by files in the volume.
		//The superclass sets this to 1 << self.hfsTextEncoding, which is correct IFF we have at least one file (we set all files to the same encoding).
		//If there are no files, then no encodings are represented, so the bitmap should be 0.
		S(vh->encodingsBitmap, 0);
	}

	copiedEverything = copiedEverything && wroteCatalog && wroteExtentsOverflow;

	return copiedEverything;
}

@end
