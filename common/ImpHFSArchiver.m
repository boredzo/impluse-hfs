//
//  ImpHFSArchiver.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2024-03-08.
//

#import "ImpHFSArchiver.h"

#import <checkint.h>

#import "ImpTextEncodingConverter.h"
#import "ImpSizeUtilities.h"
#import "ImpHydratedItem.h"
#import "ImpCatalogBuilder.h"
#import "ImpMutableBTreeFile.h"
#import "ImpBTreeHeaderNode.h"
#import "ImpHFSPlusDestinationVolume.h"
#import "ImpVirtualFileHandle.h"

ImpArchiveVolumeFormat _Nonnull const ImpArchiveVolumeFormatHFSClassic = @"HFS";
ImpArchiveVolumeFormat _Nonnull const ImpArchiveVolumeFormatHFSPlus = @"HFS+";

ImpArchiveVolumeFormat _Nullable const ImpArchiveVolumeFormatFromString(NSString *_Nonnull const volumeFormatString) {
	NSString *_Nonnull const uppercased = [[volumeFormatString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
	if ([uppercased isEqualToString:ImpArchiveVolumeFormatHFSClassic]) {
		return ImpArchiveVolumeFormatHFSClassic;
	} else if ([uppercased isEqualToString:ImpArchiveVolumeFormatHFSPlus]) {
		return ImpArchiveVolumeFormatHFSPlus;
	}

	return nil;
}

@implementation ImpHFSArchiver

- (void) deliverProgressUpdate:(double)progress
	operationDescription:(NSString *_Nonnull)operationDescription
{
	if (self.archivingProgressUpdateBlock != nil) {
		self.archivingProgressUpdateBlock(progress, operationDescription);
	}
}

- (bool)performArchivingOrReturnError:(NSError *_Nullable *_Nonnull) outError {
	//Do this right up front so if we can't even open the destination file/device, we fail early.
	int const writeFD = open(self.destinationDevice.fileSystemRepresentation, O_CREAT | O_WRONLY, 0444);
	if (writeFD < 0) {
		int const openErrno = errno;
		NSError *_Nonnull const openFailedError = [NSError errorWithDomain:NSPOSIXErrorDomain code:openErrno userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Couldn't open %@ for writing: %s", self.destinationDevice.path, strerror(openErrno)] }];
		if (outError != NULL) {
			*outError = openFailedError;
		}
		return false;
	}

	ImpBTreeVersion catalogVersion = 0;
	ImpBTreeVersion extentsOverflowVersion = 0;
	u_int16_t catBytesPerNode = 0;
	u_int16_t extBytesPerNode = 0;
	Class _Nullable dstVolClass = Nil;
	ImpHFSPlusDestinationVolume *_Nullable hfsPlusVol = nil;

	bool const isHFSPlus = (_volumeFormat == ImpArchiveVolumeFormatHFSPlus);
	bool const isHFSClassic = (_volumeFormat == ImpArchiveVolumeFormatHFSClassic);

	if (isHFSPlus) {
		catalogVersion = ImpBTreeVersionHFSPlusCatalog;
		catBytesPerNode = BTreeNodeLengthHFSPlusCatalogMinimum;
		extentsOverflowVersion = ImpBTreeVersionHFSPlusExtentsOverflow;
		extBytesPerNode = BTreeNodeLengthHFSPlusExtentsOverflowMinimum;
		dstVolClass = [ImpHFSPlusDestinationVolume class];
	} else /*if (isHFSClassic) {
		catalogVersion = ImpBTreeVersionHFSCatalog;
		catBytesPerNode = BTreeNodeLengthHFSStandard;
		extentsOverflowVersion = ImpBTreeVersionHFSExtentsOverflow;
		extBytesPerNode = BTreeNodeLengthHFSStandard;
		dstVolClass = [ImpHFSDestinationVolume class];
	} else*/ {
		NSError *_Nonnull const unknownFileSystemError = [NSError errorWithDomain:NSOSStatusErrorDomain code:extFSErr userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Can't archive to a %@ file system", _volumeFormat] }];
		if (outError != NULL) {
			*outError = unknownFileSystemError;
		}
		return false;
	}

	u_int32_t numFiles = 0;
	u_int32_t numFolders = 0;

#pragma mark Gathering source items

	NSURL *_Nullable const rootDirURL = self.sourceRootFolder;
	ImpHydratedFolder *_Nullable rootDirItem = (
		rootDirURL != nil
		? [ImpHydratedFolder itemWithRealWorldURL:rootDirURL error:outError]
		: [ImpHydratedFolder itemWithOriginalFolder]
	);
	if (! [rootDirItem isKindOfClass:[ImpHydratedFolder class]]) {
		NSError *_Nonnull const rootFolderIsNotAFolderError = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOTDIR userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Source folder is not a folder: %@", rootDirURL.path] }];
		if (outError != NULL) {
			*outError = rootFolderIsNotAFolderError;
		}
		return false;
	}
	rootDirItem.name = self.volumeName ?: rootDirURL.lastPathComponent;
	NSParameterAssert(rootDirItem.name != nil);
	rootDirItem.assignedItemID = kHFSRootFolderID;

	NSArray <ImpHydratedItem *> *_Nullable rootChildItems = [rootDirItem gatherChildrenOrReturnError:outError];
	if (! rootChildItems) {
		return false;
	}

	NSMutableSet <ImpHydratedItem *> *_Nonnull const itemsInsideTheRootFolder = [NSMutableSet setWithCapacity:rootDirItem.contents.count + self.sourceItems.count];
	rootDirItem.contents = rootChildItems;
	for (ImpHydratedItem *_Nonnull const item in rootChildItems) {
		[itemsInsideTheRootFolder addObject:item];
	}
	for (ImpHydratedItem *_Nonnull const item in self.sourceItems) {
		[itemsInsideTheRootFolder addObject:item];
	}

	//This array contains every single item to be added to the catalog, regardless of its position in the folder hierarchy. As such, the number of items in the root is not relevant; we cannot easily produce an estimate of the number of items with which to guess the capacity needed.
	//Note that numFolders does *not* get the root directory added to it. fsck_hfs confirms that counting the root directory in numFolders is incorrect.
	NSMutableArray <ImpHydratedItem *> *_Nonnull const allItems = [NSMutableArray array];
	[allItems addObject:rootDirItem];
	for (ImpHydratedItem *_Nonnull const item in itemsInsideTheRootFolder) {
		if ([item isKindOfClass:[ImpHydratedFolder class]]) {
			++numFolders;

			ImpHydratedFolder *_Nonnull const folder = (ImpHydratedFolder *)item;
			NSArray <ImpHydratedItem *> *_Nonnull const children = [folder gatherChildrenOrReturnError:outError];
			if (! children) {
				return false;
			}
			folder.contents = children;
		} else {
			++numFiles;
		}

		[item recursivelyAddItemsToArray:allItems];
	}

	u_int64_t const numItems = numFiles + numFolders;

#pragma mark Building the catalog

	//In addition to building the catalog here, we also need to develop an estimate of how much space is needed.
	u_int32_t const blockSize = kISOStandardBlockSize;
	u_int64_t volumeLength = self.volumeSizeInBytes;
	u_int64_t numBlocksInVolume;
	bool needsBlocksCounted;
	if (volumeLength > 0) {
		needsBlocksCounted = false;
		NSAssert(isHFSPlus, @"This logic works for HFS+ allocation block counting but not HFS (workaround: use --size)");
		numBlocksInVolume = ImpCeilingDivide(volumeLength, blockSize);
	} else {
		needsBlocksCounted = true;
		numBlocksInVolume = 0;
	}

	ImpCatalogBuilder *_Nonnull const catBuilder = [[ImpCatalogBuilder alloc] initWithBTreeVersion:catalogVersion bytesPerNode:catBytesPerNode expectedNumberOfItems:numItems];
	//TODO: Need to support multiple text encoding converters, particularly for HFS.
	ImpTextEncodingConverter *_Nonnull const tec = self.textEncodingConverter ?: [[ImpTextEncodingConverter alloc] initWithHFSTextEncoding:kTextEncodingMacRoman];

	HFSCatalogNodeID cnidCounter = kHFSFirstUserCatalogNodeID;

	NSMutableDictionary <ImpHydratedFile *, ImpCatalogItem *> *_Nonnull const catalogItemsForFiles = [NSMutableDictionary dictionaryWithCapacity:allItems.count];
	NSMutableArray <ImpHydratedFile *> *_Nonnull const allFiles = [NSMutableArray arrayWithCapacity:numFiles];
	for (ImpHydratedItem *_Nonnull const item in allItems) {
		item.textEncodingConverter = tec;
		//This has to be conditional because the root item already has a CNID.
		if (item.assignedItemID == 0) {
			item.assignedItemID = cnidCounter++;
		}
		if ([item isKindOfClass:[ImpHydratedFolder class]]) {
#pragma mark — Folder catalog records
			ImpHydratedFolder *_Nonnull const folder = (ImpHydratedFolder *)item;

			NSMutableData *_Nonnull const folderKey = [NSMutableData dataWithLength:isHFSPlus ? sizeof(struct HFSPlusCatalogKey) : sizeof(struct HFSCatalogKey)];
			NSMutableData *_Nonnull const folderRec = [NSMutableData dataWithLength:isHFSPlus ? sizeof(struct HFSPlusCatalogFolder) : sizeof(struct HFSCatalogFolder)];
			NSMutableData *_Nonnull const folderThreadKey = [NSMutableData dataWithLength:isHFSPlus ? sizeof(struct HFSPlusCatalogKey) : sizeof(struct HFSCatalogKey)];
			NSMutableData *_Nonnull const folderThreadRec = [NSMutableData dataWithLength:isHFSPlus ? sizeof(struct HFSPlusCatalogThread) : sizeof(struct HFSCatalogThread)];
			if (isHFSPlus) {
				bool const filledOutFolderRec = [folder fillOutHFSPlusCatalogKey:folderKey hfsPlusCatalogFolder:folderRec error:outError];
				[folder fillOutHFSPlusCatalogKey:folderThreadKey hfsPlusCatalogFolderThread:folderThreadRec];
				if (! filledOutFolderRec) {
					return false;
				}
			} else if (isHFSClassic) {
				bool const filledOutFolderRec = [folder fillOutHFSCatalogKey:folderKey hfsCatalogFolder:folderRec error:outError];
				[folder fillOutHFSCatalogKey:folderThreadKey hfsCatalogFolderThread:folderThreadRec];
				if (! filledOutFolderRec) {
					return false;
				}
			}
			ImpCatalogItem *_Nonnull const catItemForFolderRecord = [catBuilder addKey:folderKey folderRecord:folderRec];
			ImpCatalogItem *_Nonnull const catItemForThreadRecord = [catBuilder addKey:folderThreadKey threadRecord:folderThreadRec];
			NSAssert(catItemForFolderRecord == catItemForThreadRecord, @"Catalog builder didn't recognize these folder and thread records as belonging to the same item!");
			folder.catalogItem = catItemForFolderRecord;
		} else {
#pragma mark — File catalog records
			ImpHydratedFile *_Nonnull const file = (ImpHydratedFile *)item;

			u_int64_t dataForkLogicalLength = 0, rsrcForkLogicalLength = 0;
			bool const gotDFLength = [file getDataForkLength:&dataForkLogicalLength error:outError];
			bool const gotRFLength = [file getResourceForkLength:&rsrcForkLogicalLength error:outError];
			if (! gotDFLength) {
				return false;
			}
			if (! gotRFLength) {
				//Yeah, that can fail. Some files simply don't have a resource fork at all. We treat this as having a length of zero.
			}

			if (needsBlocksCounted) {
				numBlocksInVolume += ImpNextMultipleOfSize(dataForkLogicalLength, blockSize);
				numBlocksInVolume += ImpNextMultipleOfSize(rsrcForkLogicalLength, blockSize);
			}

			NSMutableData *_Nonnull const fileKey = [NSMutableData dataWithLength:isHFSPlus ? sizeof(struct HFSPlusCatalogKey) : sizeof(struct HFSCatalogKey)];
			NSMutableData *_Nonnull const fileRec = [NSMutableData dataWithLength:isHFSPlus ? sizeof(struct HFSPlusCatalogFile) : sizeof(struct HFSCatalogFile)];
			NSMutableData *_Nonnull const fileThreadKey = [NSMutableData dataWithLength:isHFSPlus ? sizeof(struct HFSPlusCatalogKey) : sizeof(struct HFSCatalogKey)];
			NSMutableData *_Nonnull const fileThreadRec = [NSMutableData dataWithLength:isHFSPlus ? sizeof(struct HFSPlusCatalogThread) : sizeof(struct HFSCatalogThread)];
			if (isHFSPlus) {
				bool const filledOutFileRec = [file fillOutHFSPlusCatalogKey:fileKey hfsPlusCatalogFile:fileRec error:outError];
				[file fillOutHFSPlusCatalogKey:fileThreadKey hfsPlusCatalogFileThread:fileThreadRec];
				if (! filledOutFileRec) {
					return false;
				}
			} else if (isHFSClassic) {
				bool const filledOutFileRec = [file fillOutHFSCatalogKey:fileKey hfsCatalogFile:fileRec error:outError];
				[file fillOutHFSCatalogKey:fileThreadKey hfsCatalogFileThread:fileThreadRec];
				if (! filledOutFileRec) {
					return false;
				}
			}
			ImpCatalogItem *_Nonnull const catItemForFileRecord = [catBuilder addKey:fileKey fileRecord:fileRec];
			ImpCatalogItem *_Nonnull const catItemForThreadRecord = [catBuilder addKey:fileThreadKey threadRecord:fileThreadRec];
			NSAssert(catItemForFileRecord == catItemForThreadRecord, @"Catalog builder didn't recognize these file and thread records as belonging to the same item!");
			catalogItemsForFiles[file] = catItemForFileRecord;
			file.catalogItem = catItemForFileRecord;
			[allFiles addObject:file];
		}
	}

	ImpMutableBTreeFile *_Nonnull const catTree = [[ImpMutableBTreeFile alloc] initWithVersion:catalogVersion bytesPerNode:catBytesPerNode nodeCount:catBuilder.totalNodeCount];
//	[catBuilder populateTree:catTree];
	u_int32_t const catalogBlockCount = (u_int32_t)ImpCeilingDivide([catTree lengthInBytes], (u_int64_t)blockSize);

	ImpMutableBTreeFile *_Nonnull const extentsOverflowTree = [[ImpMutableBTreeFile alloc] initWithVersion:extentsOverflowVersion bytesPerNode:extBytesPerNode nodeCount:2];
	ImpBTreeHeaderNode *_Nonnull const extHeader = extentsOverflowTree.headerNode;
	[extHeader reviseHeaderRecord:^(struct BTHeaderRec *_Nonnull const headerPtr) {
		S(headerPtr->totalNodes, 2);
		S(headerPtr->freeNodes, 1);
		S(headerPtr->treeDepth, 0);
	}];

	u_int32_t const extentsOverflowBlockCount = (u_int32_t)([extentsOverflowTree lengthInBytes] / (u_int64_t)blockSize);

	if (needsBlocksCounted) {
		/*We need to finish up our arithmetic. We now know the total physical length of all forks; we also need to add:
		 *- the allocations file
		 *- the catalog file
		 *- the extents overflow file
		 *- the preamble (boot blocks + volume header = 3 ISO standard blocks)
		 *- the postamble (alternate volume header + empty space = 2 ISO standard blocks)
		 *
		 *We need to finalize volumeLength so we can use it to create the destination volume object—which means we can't use the destination volume to tell us the allocations file's size. We'll need to compute that ourselves. This is a bit of a circular dependency, as the volume size needs to include space for the allocations file, and the allocations file's size is determined by the volume's size.
		 *Fortunately, growing the volume grows the allocations file at a diminished rate: One ISO standard block in the allocations file tracks 4,096 blocks in the volume. So for every 4,096 blocks in the volume, we add one block to the allocations file; we would need to add up to 4,096 blocks to the allocations file to need to add another block to the allocations file to track them.
		 *(Complicating this math is the fact that the amount of spare space in the allocations file might not be enough to cover its own size.)
		 */
		u_int64_t const numBlocksInForks = numBlocksInVolume;
		u_int64_t const numBlocksInPreamble = 3;
		u_int64_t const numBlocksInPostamble = 2;
		//The 0 represents numBlocksInAllocations, which we're about to calculate.
		numBlocksInVolume = numBlocksInPreamble + 0 + extentsOverflowBlockCount + catalogBlockCount + numBlocksInForks + numBlocksInPostamble;
		u_int64_t numBlocksInAllocations = ImpCeilingDivide(numBlocksInVolume, 8);
		u_int64_t prevNumBlocksInAllocations = numBlocksInAllocations;
		do {
			prevNumBlocksInAllocations = numBlocksInAllocations;
			numBlocksInAllocations = ImpCeilingDivide(numBlocksInVolume + numBlocksInAllocations, 8);
		} while (numBlocksInAllocations != prevNumBlocksInAllocations);
		numBlocksInVolume += numBlocksInAllocations;
		volumeLength = numBlocksInVolume * blockSize;
	}

#pragma mark Creating the destination volume

	off_t volumeStartOffset = 0;

	ImpDestinationVolume *_Nullable dstVol = nil;
	dstVol = [[dstVolClass alloc] initForWritingToFileDescriptor:writeFD startAtOffset:volumeStartOffset expectedLengthInBytes:volumeLength];
	NSAssert(isHFSPlus, @"This part doesn't support HFS Classic yet");
	if (_volumeFormat == ImpArchiveVolumeFormatHFSPlus) {
		hfsPlusVol = (ImpHFSPlusDestinationVolume *)dstVol;
		NSAssert(numBlocksInVolume <= UINT32_MAX, @"Volume too big! Can't create a volume with %llu blocks.", numBlocksInVolume);
	}

#pragma mark Filling out the volume header, part 1

	//We need to fill out a large swath of the volume header up front for initializing the allocations file to work.

	u_int64_t encodingsBitmap = 1 << kTextEncodingMacRoman;
	//In HFS Plus, no old-school HFS encodings were used—everything was Unicode coming in. So all the items are recorded with an encoding of zero… which is MacRoman.
	//TODO: We might need to try a series of encoders anyway in order to compute an appropriate encoding hint for each item for use on classic Mac OS.
	//In HFS Classic, it will need to be populated with the encoding used for each item's name.

	NSAssert(isHFSPlus, @"This part doesn't support HFS Classic yet");
	struct HFSPlusVolumeHeader *_Nonnull const vh = [hfsPlusVol mutableVolumeHeaderPointer];
	S(vh->signature, kHFSPlusSigWord);
	S(vh->version, kHFSPlusVersion);
	u_int32_t const volumeAttributes = (0
		| kHFSVolumeUnmountedMask
		| kHFSVolumeSoftwareLockMask
		| (catBuilder.hasReusedCatalogNodeIDs ? kHFSCatalogNodeIDsReusedMask : 0)
	);
	S(vh->attributes, volumeAttributes);
	S(vh->lastMountedVersion, kHFSPlusMountVersion);
	S(vh->journalInfoBlock, 0);
	//NOTE: TN1150 says that while most dates are recorded in HFS+ as GMT, the creation date in the volume header is specifically local time, because it was used as a volume identifier by some applications, and converting it between time zones could break those comparisons.
	//TODO: Time zone offset should be an option.
	NSDate *_Nonnull const now = [NSDate date];
	u_int32_t const nowLocal = [ImpHydratedItem hfsDateForDate:now timeZoneOffset:[[NSTimeZone localTimeZone] secondsFromGMTForDate:now]];
	//Reminder that UTC and GMT are not actually the same thing!
	u_int32_t const nowGMT = [ImpHydratedItem hfsDateForDate:now timeZoneOffset:[[NSTimeZone timeZoneWithAbbreviation:@"UTC"] secondsFromGMTForDate:now]];
	//Confirmed by experiment (creating an HFS+ volume in a read-only disk image with hdiutil): while create date is stored in local time, modify date is stored in GMT as usual.
	S(vh->createDate, nowLocal);
	S(vh->modifyDate, nowGMT);
	S(vh->backupDate, 0);
	S(vh->checkedDate, 0);
	S(vh->fileCount, numFiles);
	S(vh->folderCount, numFolders);
	/*Filled out by dstVol when we initialize the allocations file and updated when we allocate blocks:
	S(vh->blockSize, (u_int32_t)dstVol.numberOfBytesPerBlock);
	S(vh->totalBlocks, (u_int32_t)dstVol.numberOfBlocksTotal);
	S(vh->freeBlocks, (u_int32_t)[hfsPlusVol numberOfBlocksFreeAccordingToWorkingBitmap]);
	S(vh->nextAllocation, (u_int32_t)[hfsPlusVol firstUnusedBlockInWorkingBitmap]);
	S(vh->rsrcClumpSize, blockSize);
	S(vh->dataClumpSize, blockSize * 4);
	S(vh->nextCatalogID, catBuilder.nextCatalogNodeID);
	 */
	S(vh->writeCount, (u_int32_t)1);
	S(vh->encodingsBitmap, encodingsBitmap);

	///Entries in the finderInfo array in an HFS Plus volume header according to TN1150.
	typedef NS_ENUM(u_int32_t, ImpHFSPlusFinderInfoIndex) {
		///Quoth TN1150: “finderInfo[0] contains the directory ID of the directory containing the bootable system (for example, the System Folder in Mac OS 8 or 9, or /System/Library/CoreServices in Mac OS X). It is zero if there is no bootable system on the volume. This value is typically equal to either finderInfo[3] or finderInfo[5].”
		ImpHFSPlusFinderInfoIndexBlessedSystemFolder,
		///Quoth TN1150: “finderInfo[1] contains the parent directory ID of the startup application (for example, Finder), or zero if the volume is not bootable.”
		ImpHFSPlusFinderInfoEntryStartupApplicationParentID,
		///Quoth TN1150: “finderInfo[2] contains the directory ID of a directory whose window should be displayed in the Finder when the volume is mounted, or zero if no directory window should be opened. In traditional Mac OS, this is the first in a linked list of windows to open; the frOpenChain field of the directory's Finder Info contains the next directory ID in the list. The open window list is deprecated. The Mac OS X Finder will open this directory's window, but ignores the rest of the open window list. The Mac OS X Finder does not modify this field.”
		ImpHFSPlusFinderInfoEntryFolderToOpenOnMount,
		///Quoth TN1150: “finderInfo[3] contains the directory ID of a bootable Mac OS 8 or 9 System Folder, or zero if there isn't one.”
		ImpHFSPlusFinderInfoEntryClassicMacOSSystemFolderID,
		///Quoth TN1150: “finderInfo[4] is reserved.”
		ImpHFSPlusFinderInfoEntryReserved,
		///Quoth TN1150: “finderInfo[5] contains the directory ID of a bootable Mac OS X system (the /System/Library/CoreServices directory), or zero if there is no bootable Mac OS X system on the volume.”
		ImpHFSPlusFinderInfoEntryMacOSXCoreServicesFolderID,
		///Quoth TN1150: “finderInfo[6] and finderInfo[7] are used by Mac OS X to contain a 64-bit unique volume identifier. One use of this identifier is for tracking whether a given volume's ownership (user ID) information should be honored. These elements may be zero if no such identifier has been created for the volume.”
		ImpHFSPlusFinderInfoEntryVolumeIdentifierPart1,
		///See ImpHFSPlusFinderInfoEntryVolumeIdentifierPart1.
		ImpHFSPlusFinderInfoEntryVolumeIdentifierPart2,
		///The number of 32-bit values in the finderInfo array in an HFS Plus volume header. In HFS, this was defined (at least publicly) the other way around, as an array of 32 bytes with no further explanation.
		ImpHFSPlusFinderInfoNum32BitValues
	};
	//TODO: Look for System and Finder files in the catalog and set the appropriate folders to the highest Mac OS 9 and Mac OS X versions found.
	memset(vh->finderInfo, 0, sizeof(vh->finderInfo));

	[hfsPlusVol volumeHeaderIsMostlyInitialized];
	[hfsPlusVol writeTemporaryPreamble:outError];

#pragma mark Allocating and writing the special files

	NSAssert(isHFSPlus, @"This part doesn't support HFS Classic yet");
	[hfsPlusVol initializeAllocationBitmapWithBlockSize:blockSize count:(u_int32_t)numBlocksInVolume];

	HFSPlusExtentRecord catalogExtents = { { 0, 0 }, { 0, 0 } };
	struct HFSPlusExtentDescriptor const *_Nonnull const catExtentsPtr = catalogExtents;
	bool const allocatedCatalog = [hfsPlusVol allocateBlocks:catalogBlockCount forFork:ImpForkTypeSpecialFileContents getExtent:&catalogExtents[0]];
	if (! allocatedCatalog) {
		NSError *_Nonnull const noSpaceForCatError = [NSError errorWithDomain:NSOSStatusErrorDomain code:dskFulErr userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Could not allocate %llu bytes for catalog in new volume", catTree.lengthInBytes] }];
		if (outError != NULL) {
			*outError = noSpaceForCatError;
		}
		return false;
	}

	HFSPlusExtentRecord extentsOverflowExtents = { { 0, 0 }, { 0, 0 } };
	struct HFSPlusExtentDescriptor const *_Nonnull const extExtentsPtr = extentsOverflowExtents;
	bool const allocatedExtentsOverflow = [hfsPlusVol allocateBlocks:extentsOverflowBlockCount forFork:ImpForkTypeSpecialFileContents getExtent:extentsOverflowExtents];
	if (! allocatedExtentsOverflow) {
		NSError *_Nonnull const noSpaceForExtError = [NSError errorWithDomain:NSOSStatusErrorDomain code:dskFulErr userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Could not allocate %llu bytes for extents overflow tree in new volume", extentsOverflowTree.lengthInBytes] }];
		if (outError != NULL) {
			*outError = noSpaceForExtError;
		}
		return false;
	}

#if 0
	__block bool wroteCatalog = false;
	__block NSError *_Nullable catWriteError = nil;
	[catTree serializeToData:^(NSData *const  _Nonnull data) {
		ImpVirtualFileHandle *_Nonnull const catFH = [dstVol fileHandleForWritingToExtents:catExtentsPtr];
		wroteCatalog = [catFH writeData:data error:&catWriteError];
	}];
	if (! wroteCatalog) {
		if (outError != NULL) {
			*outError = catWriteError;
		}
		return false;
	}
	__block bool wroteExtentsOverflow = false;
	__block NSError *_Nullable extWriteError = nil;
	[extentsOverflowTree serializeToData:^(NSData *const  _Nonnull data) {
		ImpVirtualFileHandle *_Nonnull const extFH = [dstVol fileHandleForWritingToExtents:extExtentsPtr];
		wroteExtentsOverflow = [extFH writeData:data error:&extWriteError];
	}];
	if (! wroteExtentsOverflow) {
		if (outError != NULL) {
			*outError = extWriteError;
		}
		return false;
	}
#endif

#pragma mark Allocating the destination files' forks

	__block bool allocatedAllForks = true;
	__block ImpHydratedFile *_Nullable fileThatCouldNotBeAllocated = nil;
	__block u_int64_t allocationShortfall = 0;
	__block NSError *_Nullable allocationError = nil;
//	[catalogItemsForFiles enumerateKeysAndObjectsUsingBlock:^(ImpHydratedFile *_Nonnull const file, ImpCatalogItem *_Nonnull const catItem, BOOL *_Nonnull const stop) {
	[allFiles enumerateObjectsUsingBlock:^(ImpHydratedFile *_Nonnull const file, NSUInteger const idx, BOOL *_Nonnull const stop) {
		ImpCatalogItem *_Nonnull const catItem = file.catalogItem;

		HFSPlusExtentRecord dataExtents = { { 0 } };
		HFSPlusExtentRecord rsrcExtents = { { 0 } };
		u_int64_t dataForkLogicalLength = 0, rsrcForkLogicalLength = 0;
		bool const gotDFLength = [file getDataForkLength:&dataForkLogicalLength error:&allocationError];
		bool const gotRFLength = [file getResourceForkLength:&rsrcForkLogicalLength error:&allocationError];
		if (! gotDFLength) {
			allocatedAllForks = false;
			*stop = true;
		}
		if (! gotRFLength) {
			//As above, this can fail even on an extant file, so we consider it non-fatal.
		}
		u_int64_t const unallocatedDataBytes = [hfsPlusVol allocateBytes:dataForkLogicalLength forFork:ImpForkTypeData populateExtentRecord:dataExtents];
		u_int64_t const unallocatedRsrcBytes = [hfsPlusVol allocateBytes:rsrcForkLogicalLength forFork:ImpForkTypeResource populateExtentRecord:rsrcExtents];
		if (unallocatedDataBytes > 0 || unallocatedRsrcBytes > 0) {
			fileThatCouldNotBeAllocated = file;
			allocationShortfall = unallocatedDataBytes ?: unallocatedRsrcBytes;
			NSError *_Nonnull const diskFullError = [NSError errorWithDomain:NSOSStatusErrorDomain code:dskFulErr userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Ran out of space trying to allocate space for %@ (at least %llu bytes short)", file.realWorldURL.path, allocationShortfall] }];
			allocationError = diskFullError;
			allocatedAllForks = false;
			*stop = true;
		}
		[file setDataForkHFSPlusExtentRecord:dataExtents];
		[file setResourceForkHFSPlusExtentRecord:rsrcExtents];

		NSMutableData *_Nonnull const fileRecData = catItem.destinationRecord;
		//TODO: In theory, this should be the hydrated item's job. Maybe a new method to just copy its extents into an existing file record.
		struct HFSPlusCatalogFile *_Nonnull const fileRecPtr = fileRecData.mutableBytes;
		memcpy(fileRecPtr->dataFork.extents, dataExtents, sizeof(fileRecPtr->dataFork.extents));
		S(fileRecPtr->dataFork.totalBlocks, (u_int32_t)ImpNumberOfBlocksInHFSPlusExtentRecord(dataExtents));
		memcpy(fileRecPtr->resourceFork.extents, rsrcExtents, sizeof(fileRecPtr->resourceFork.extents));
		S(fileRecPtr->resourceFork.totalBlocks, (u_int32_t)ImpNumberOfBlocksInHFSPlusExtentRecord(rsrcExtents));
		if (file.assignedItemID == 41) {
			ImpPrintf(@"Beep boop!");
		}
	}];

	if (! allocatedAllForks) {
		if (outError != NULL) {
			*outError = allocationError;
		}
		return false;
	}

#pragma mark Writing the source files' forks

	NSAssert(isHFSPlus, @"This part doesn't support HFS Classic yet");
	for (ImpHydratedItem *_Nonnull const item in allItems) {
		if ([item isKindOfClass:[ImpHydratedFile class]]) {
			ImpHydratedFile *_Nonnull const file = (ImpHydratedFile *)item;
			[self deliverProgressUpdate:0.0 operationDescription:[NSString stringWithFormat:@"Copying %@…", file.realWorldURL.relativePath]];

			HFSPlusExtentRecord extents;
			__block NSError *_Nullable copyError = nil;
			ImpVirtualFileHandle *_Nullable writeFH = nil;
			NSMutableData *_Nonnull const fileRecData = [catalogItemsForFiles[file] destinationRecord];
			struct HFSPlusCatalogFile *_Nonnull const fileRecPtr = fileRecData.mutableBytes;

			[file getDataForkHFSPlusExtentRecord:extents];
			writeFH = [hfsPlusVol fileHandleForWritingToExtents:extents];
			bool const copiedDataFork = [file readDataFork:^bool(NSData *_Nonnull const data) {
				NSUInteger remaining = data.length;
				NSInteger written;
				do {
					written = [writeFH writeData:data error:&copyError];
					if (written > 0) {
						remaining -= written;
					}
				}
				while (written > 0 && remaining > 0);
				return remaining == 0;
			} error:&copyError];
			if (! copiedDataFork) {
				NSError *_Nonnull const copyFailedError = [NSError errorWithDomain:copyError.domain code:copyError.code userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed copying the data fork of %@", file.realWorldURL.path], NSUnderlyingErrorKey: copyError }];
				if (outError != NULL) {
					*outError = copyFailedError;
				}
				return false;
			}
//			memcpy(fileRecPtr->dataFork.extents, extents, sizeof(fileRecPtr->dataFork.extents));
//			S(fileRecPtr->dataFork.totalBlocks, (u_int32_t)ImpNumberOfBlocksInHFSPlusExtentRecord(extents));

			[file getResourceForkHFSPlusExtentRecord:extents];
			writeFH = [hfsPlusVol fileHandleForWritingToExtents:extents];
			bool const copiedRsrcFork = [file readResourceFork:^bool(NSData *_Nonnull const data) {
				NSUInteger remaining = data.length;
				NSInteger written;
				do {
					if (file.assignedItemID == 41) {
						ImpPrintf(@"Beep boop!");
					}
					written = [writeFH writeData:data error:&copyError];
					if (written > 0) {
						remaining -= written;
					}
				}
				while (written > 0 && remaining > 0);
				return remaining == 0;
			} error:&copyError];
			if (! copiedRsrcFork) {
				NSError *_Nonnull const copyFailedError = [NSError errorWithDomain:copyError.domain code:copyError.code userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed copying the resource fork of %@", file.realWorldURL.path], NSUnderlyingErrorKey: copyError }];
				if (outError != NULL) {
					*outError = copyFailedError;
				}
				return false;
			}
			memcpy(fileRecPtr->resourceFork.extents, extents, sizeof(fileRecPtr->resourceFork.extents));
			S(fileRecPtr->resourceFork.totalBlocks, (u_int32_t)ImpNumberOfBlocksInHFSPlusExtentRecord(extents));
			if (file.assignedItemID == 41) {
				ImpPrintf(@"Beep boop!");
			}
			sleep(0);
		}
	}

#pragma mark Writing the special files

	//We need to repopulate the tree since we've just been changing files' catalog records.
	[catBuilder catalogItemsAreDirty];
	[catBuilder populateTree:catTree];

	__block bool wroteCatalog = false;
	__block NSError *_Nullable catWriteError = nil;
	[catTree serializeToData:^(NSData *const  _Nonnull data) {
		ImpVirtualFileHandle *_Nonnull const catFH = [dstVol fileHandleForWritingToExtents:catExtentsPtr];
		wroteCatalog = [catFH writeData:data error:&catWriteError];
	}];
	if (! wroteCatalog) {
		if (outError != NULL) {
			*outError = catWriteError;
		}
		return false;
	}
	__block bool wroteExtentsOverflow = false;
	__block NSError *_Nullable extWriteError = nil;
	[extentsOverflowTree serializeToData:^(NSData *const  _Nonnull data) {
		ImpVirtualFileHandle *_Nonnull const extFH = [dstVol fileHandleForWritingToExtents:extExtentsPtr];
		wroteExtentsOverflow = [extFH writeData:data error:&extWriteError];
	}];
	if (! wroteExtentsOverflow) {
		if (outError != NULL) {
			*outError = extWriteError;
		}
		return false;
	}

#pragma mark Filling out the volume header, part 2

	//The volume initialized the allocationFile member on its own when creating the allocations bitmap.
	memcpy(vh->extentsFile.extents, extentsOverflowExtents, sizeof(vh->extentsFile.extents));
	S(vh->extentsFile.totalBlocks, (u_int32_t)ImpNumberOfBlocksInHFSPlusExtentRecord(extentsOverflowExtents));
	S(vh->extentsFile.logicalSize, extentsOverflowTree.lengthInBytes);
	S(vh->extentsFile.clumpSize, extentsOverflowTree.bytesPerNode);
	memcpy(vh->catalogFile.extents, catalogExtents, sizeof(vh->catalogFile.extents));
	S(vh->catalogFile.totalBlocks, (u_int32_t)ImpNumberOfBlocksInHFSPlusExtentRecord(catalogExtents));
	S(vh->catalogFile.logicalSize, catTree.lengthInBytes);
	//Surprisingly, fsck_hfs has an opinion about this, in spite of there being no recommendation that I've seen in the docs about what the clump size should be.
	S(vh->catalogFile.clumpSize, catTree.bytesPerNode * 2);
	memset(&vh->attributesFile, 0, sizeof(vh->attributesFile));
	memset(&vh->startupFile, 0, sizeof(vh->startupFile));

	//Most members related to allocations are updated as the allocator hands out blocks (including nextAllocation), but freeBlocks is left to be updated at the end—which is where we now are.
	S(vh->freeBlocks, (u_int32_t)[hfsPlusVol numberOfBlocksFreeAccordingToWorkingBitmap]);

#pragma mark Flushing to disk

	[hfsPlusVol flushVolumeStructures:outError];

	return true;
}

@end

u_int64_t ImpParseSizeSpecification(NSString *_Nonnull const sizeSpec) {
	static NSDictionary <NSString *, NSString *> *_Nullable wellKnownSizeSpecNames = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		wellKnownSizeSpecNames =@{
			@"hdfloppy": @"1440K",
			@"hd20":     @"20M",
			@"hd20sc":   @"20M",
			@"hd40sc":   @"40M",
			@"hd80sc":   @"80M",
			@"floppy":   @"0x1440", //ImpVolumeSizeSmallestPossibleFloppy
		};
	});

	NSString *_Nullable const resolvedSizeSpec = wellKnownSizeSpecNames[sizeSpec];
	if (resolvedSizeSpec == nil) {
		return 0;
	}

	//Adapted from the size-spec parser of truncate: https://github.com/boredzo/truncate/blob/main/truncate.c
	char const *_Nonnull const cStringPtr = resolvedSizeSpec.UTF8String;
	char const *afterSize = NULL;
	unsigned long long int size = strtoll(cStringPtr, (char **)&afterSize, 0);
	while (isspace(*afterSize) && *afterSize != '\0') ++afterSize;

	unsigned long long int sizeMultiplier = 1ULL;
	switch (*afterSize) {
		case 'b': case 'B':
			sizeMultiplier = 1ULL;
			break;
		case 's': case 'S':
			sizeMultiplier = 512ULL;
			break;
		case 'k': case 'K':
			sizeMultiplier = 1024ULL;
			break;
		case 'm': case 'M':
			sizeMultiplier = 1024ULL * 1024ULL;
			break;
		case 'g': case 'G':
			sizeMultiplier = 1024ULL * 1024ULL * 1024ULL;
			break;
		case 't': case 'T':
			sizeMultiplier = 1024ULL * 1024ULL * 1024ULL * 1024ULL;
			break;
		case 'p': case 'P':
			sizeMultiplier = 1024ULL * 1024ULL * 1024ULL * 1024ULL * 1024ULL;
			break;
		case 'e': case 'E':
			sizeMultiplier = 1024ULL * 1024ULL * 1024ULL * 1024ULL * 1024ULL * 1024ULL;
			break;
		case 'z': case 'Z':
			sizeMultiplier = 1024ULL * 1024ULL * 1024ULL * 1024ULL * 1024ULL * 1024ULL * 1024ULL;
			break;
		case 'y': case 'Y':
			sizeMultiplier = 1024ULL * 1024ULL * 1024ULL * 1024ULL * 1024ULL * 1024ULL * 1024ULL * 1024ULL;
			break;
	}

	int32_t error = CHECKINT_NO_ERROR;
	u_int64_t product = check_uint64_mul(size, sizeMultiplier, &error);
	if (error) {
		ImpPrintf(@"'%@' (resolved to %llu %c) is too big!", sizeSpec, size, *afterSize);
		return 0;
	}
	return product;
}
