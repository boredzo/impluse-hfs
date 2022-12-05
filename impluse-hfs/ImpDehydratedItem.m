//
//  ImpDehydratedItem.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-02.
//

#import "ImpDehydratedItem.h"

#import "ImpTextEncodingConverter.h"

#import "ImpHFSVolume.h"
#import "ImpBTreeFile.h"
#import "ImpBTreeNode.h"

@interface ImpDehydratedItem ()

- (bool) rehydrateFileAtRealWorldURL:(NSURL *_Nonnull const)realWorldURL error:(NSError *_Nullable *_Nonnull const)outError;
- (bool) rehydrateFolderAtRealWorldURL:(NSURL *_Nonnull const)realWorldURL error:(NSError *_Nullable *_Nonnull const)outError;

@end

static NSTimeInterval hfsEpochTISRD = -3061152000.0; //1904-01-01T00:00:00Z timeIntervalSinceReferenceDate

@implementation ImpDehydratedItem
{
	NSArray <NSString *> *_cachedPath;
}

- (instancetype _Nonnull) initWithHFSVolume:(ImpHFSVolume *_Nonnull const)hfsVol catalogNodeID:(HFSCatalogNodeID const)cnid {
	if ((self = [super init])) {
		self.hfsVolume = hfsVol;
		self.catalogNodeID = cnid;
	}
	return self;
}

- (instancetype _Nonnull) initWithHFSVolume:(ImpHFSVolume *_Nonnull const)hfsVol	catalogNodeID:(HFSCatalogNodeID const)cnid
	key:(struct HFSCatalogKey const *_Nonnull const)key
	fileRecord:(struct HFSCatalogFile const *_Nonnull const)fileRec
{
	if ((self = [self initWithHFSVolume:hfsVol catalogNodeID:cnid])) {
		self.hfsCatalogKeyData = [NSData dataWithBytesNoCopy:(void *)key length:sizeof(*key) freeWhenDone:false];
		self.hfsFileCatalogRecordData = [NSData dataWithBytesNoCopy:(void *)fileRec length:sizeof(*fileRec) freeWhenDone:false];

		self.type = ImpDehydratedItemTypeFile;
	}
	return self;
}

- (instancetype _Nonnull) initWithHFSVolume:(ImpHFSVolume *_Nonnull const)hfsVol catalogNodeID:(HFSCatalogNodeID const)cnid
	key:(struct HFSCatalogKey const *_Nonnull const)key
	folderRecord:(struct HFSCatalogFolder const *_Nonnull const)folderRec
{
	if ((self = [self initWithHFSVolume:hfsVol catalogNodeID:cnid])) {
		self.hfsCatalogKeyData = [NSData dataWithBytesNoCopy:(void *)key length:sizeof(*key) freeWhenDone:false];
		self.hfsFolderCatalogRecordData = [NSData dataWithBytesNoCopy:(void *)folderRec length:sizeof(*folderRec) freeWhenDone:false];

		self.type = ImpDehydratedItemTypeFolder;
	}
	return self;
}

- (bool) isDirectory {
	return self.type == ImpDehydratedItemTypeFolder;
}

- (NSString *_Nonnull const) nameFromEncoding:(TextEncoding)hfsTextEncoding {
	ImpTextEncodingConverter *_Nonnull const tec = [ImpTextEncodingConverter converterWithHFSTextEncoding:hfsTextEncoding];
	struct HFSCatalogKey const *_Nonnull const catalogKey = (struct HFSCatalogKey const *_Nonnull const)(self.hfsCatalogKeyData.bytes);
	return [tec stringForPascalString:catalogKey->nodeName];
}
- (NSString *_Nonnull const) name {
	return [self nameFromEncoding:self.hfsTextEncoding];
}

- (u_int32_t) hfsDateForDate:(NSDate *_Nonnull const)dateToConvert {
	return dateToConvert.timeIntervalSinceReferenceDate - hfsEpochTISRD;
}
- (NSDate *_Nonnull const) dateForHFSDate:(u_int32_t const)hfsDate {
	return [NSDate dateWithTimeIntervalSinceReferenceDate:hfsDate + hfsEpochTISRD];
}

///Search the catalog for parent items until reaching the volume root, then return the path so constructed.
- (NSArray <NSString *> *_Nonnull const) path {
	if (_cachedPath == nil) {
		ImpTextEncodingConverter *_Nonnull const tec = [ImpTextEncodingConverter converterWithHFSTextEncoding:self.hfsTextEncoding];

		NSMutableArray <NSString *> *_Nonnull const path = [NSMutableArray arrayWithCapacity:8];
		[path addObject:self.name];

		ImpBTreeFile *_Nonnull const catalog = self.hfsVolume.catalogBTree;
		NSData *_Nullable keyData = nil;
		struct HFSCatalogKey const *_Nonnull const ownCatalogKey = self.hfsCatalogKeyData.bytes;
		HFSCatalogNodeID nextParentID = L(ownCatalogKey->parentID);
		NSData *_Nullable threadRecordData = nil;

		//Keep ascending directories until we reach kHFSRootParentID, which is the parent of the root directory.
		while (nextParentID != kHFSRootParentID && [catalog searchCatalogTreeForItemWithParentID:nextParentID name:"\p" getRecordKeyData:&keyData threadRecordData:&threadRecordData]) {
			struct HFSCatalogThread const *_Nonnull const threadPtr = threadRecordData.bytes;
			NSString *_Nonnull const name = [tec stringForPascalString:threadPtr->nodeName];
			ImpPrintf(@"Parent of %@ is %@", path[0], name);
			[path insertObject:name atIndex:0];
			nextParentID = L(threadPtr->parentID);
		}
		NSLog(@"Catalog searches complete. Item path is: %@", [path componentsJoinedByString:@":"]);

		_cachedPath = path;
	}

	return _cachedPath;
}

- (bool) rehydrateIntoRealWorldDirectoryAtURL:(NSURL *_Nonnull const)realWorldParentURL error:(NSError *_Nullable *_Nonnull const)outError {
	return [self rehydrateAtRealWorldURL:[realWorldParentURL URLByAppendingPathComponent:self.name isDirectory:self.isDirectory] error:outError];
}
- (bool) rehydrateAtRealWorldURL:(NSURL *_Nonnull const)realWorldURL error:(NSError *_Nullable *_Nonnull const)outError {
	NSError *_Nullable reachabilityCheckError = nil;
	bool const alreadyExists = [realWorldURL checkResourceIsReachableAndReturnError:&reachabilityCheckError];
	if (alreadyExists) {
		NSDictionary <NSString *, NSObject *> *_Nonnull const userInfo = [NSDictionary dictionaryWithObjectsAndKeys:[NSString stringWithFormat:NSLocalizedString(@"Output file %@ already exists; not overwriting", /*comment*/ @""), realWorldURL.path], NSLocalizedDescriptionKey,
			reachabilityCheckError, NSUnderlyingErrorKey,
			nil];
		NSError *_Nonnull const alreadyExistsError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteFileExistsError userInfo:userInfo];
		if (outError != NULL) {
			*outError = alreadyExistsError;
		}
		return false;
	}

	if (self.isDirectory) {
		return [self rehydrateFolderAtRealWorldURL:realWorldURL error:outError];
	} else {
		return [self rehydrateFileAtRealWorldURL:realWorldURL error:outError];
	}
}

- (bool) POSIX_rehydrateFileAtRealWorldURL:(NSURL *_Nonnull const)realWorldURL error:(NSError *_Nullable *_Nonnull const)outError {
	struct HFSCatalogFile const *_Nonnull const fileRec = (struct HFSCatalogFile const *_Nonnull const)self.hfsFileCatalogRecordData.bytes;

	//TODO: This implementation will overwrite the destination file if it already exists. The client should probably check for that and prompt for confirmation…

	NSByteCountFormatter *_Nonnull const bcf = [NSByteCountFormatter new];
	off_t const dataForkSize = L(fileRec->dataLogicalSize);
	off_t const rsrcForkSize = L(fileRec->rsrcLogicalSize);
	//TODO: Probably should make sure both of these are non-negative and return a read error if we find a fork with a negative size.
	unsigned long long const totalForksSize = dataForkSize + rsrcForkSize;

	//First thing, create the file. We can set some metadata while we're at it, so do that.
	bool const isLocked = L(fileRec->flags) & kHFSFileLockedMask;
	struct FileInfo const *_Nonnull const sourceFinderInfo = (struct FileInfo const *_Nonnull const)&(fileRec->userInfo);
	struct FileInfo swappedFinderInfo = {
		.fileType = L(sourceFinderInfo->fileType),
		.fileCreator = L(sourceFinderInfo->fileCreator),
		.finderFlags = L(sourceFinderInfo->finderFlags),
		.location = {
			.h = L(sourceFinderInfo->location.h),
			.v = L(sourceFinderInfo->location.v),
		},
		.reservedField = L(sourceFinderInfo->reservedField),
	};
	NSDictionary <NSFileAttributeKey, NSObject *> *_Nonnull const resourceProperties = @{
		NSFileCreationDate: [self dateForHFSDate:L(fileRec->createDate)],
		NSFileModificationDate: [self dateForHFSDate:L(fileRec->modifyDate)],
//		NSFileImmutable: @(isLocked), //While this does work, creating the file with this set is not going to help in writing the contents to it. Don't set the locked bit until we're done populating the forks.
//		NSFileHFSTypeCode: @(swappedFinderInfo.fileType),
		NSFileHFSTypeCode: [NSNumber numberWithInt:'bzy '], //Set this temporarily so the Finder doesn't take an interest until we're done.
		NSFileHFSCreatorCode: @(swappedFinderInfo.fileCreator),
		NSFileBusy: @true,
	};
	bool const created = [[NSFileManager defaultManager] createFileAtPath:realWorldURL.path contents:nil attributes:resourceProperties];
	if (! created) {
		NSError *_Nonnull const cantCreateError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedString(@"Couldn't create real-world file", @"") }];
		if (outError != NULL) *outError = cantCreateError;
		return false;
	}

	NSURL *_Nonnull const dataForkURL = realWorldURL;
	NSFileHandle *_Nonnull const dataForkFH = [NSFileHandle fileHandleForWritingToURL:dataForkURL error:outError];
	if (dataForkFH == nil) {
		//We couldn't even open the data fork, which probably means a permission error or something.
		NSError *_Nonnull const cantCreateError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedString(@"Couldn't open real-world file for writing", @"") }];
		if (outError != NULL) *outError = cantCreateError;
		return false;
	}

	NSURL *_Nonnull const rsrcForkURL = [[realWorldURL URLByAppendingPathComponent:@"..namedfork" isDirectory:true] URLByAppendingPathComponent:@"rsrc" isDirectory:false];
	NSFileHandle *_Nullable rsrcForkFH = nil;

	int truncateResult = 0;
	bool const resourceForkIsNonEmpty = rsrcForkSize > 0;
	if (resourceForkIsNonEmpty) {
		/*OK, we've got a few things to do.
		 *If the file has a non-empty resource fork, then we also want to copy that over. That means the destination needs to have enough space for both forks in total.
		 *We don't want to copy over one fork without the other. For some files, copying the data fork without the resource fork is fine (the resource fork might just be a custom icon or something); for others, copying the resource fork without the data fork is fine (68k apps were frequently resource-fork-only). But we can't assume that in either direction.
		 *So what we do is:
		 *1. Create both files. (If *that* fails, the disk really is severely out of space—or we have other problems—and nothing down the line is going to work.)
		 *2. Truncate the data fork to the total size of *both* forks. If that succeeds, we have (for the moment at least) enough space.
		 *3. Truncate the data fork back to the data fork size only.
		 *4. Truncate the resource fork to the resource fork size only.
		 *5. Copy both forks in turn.
		 *6. If any of this fails, unlink the file and bail.
		 */

		//And yes, we do have to create the resource fork, too.
		bool const createdRF = [[NSFileManager defaultManager] createFileAtPath:rsrcForkURL.path contents:nil attributes:nil];
		FSRef ref;
		bool const createdRef = CFURLGetFSRef((__bridge CFURLRef)realWorldURL, &ref);
		if (createdRef) {
			HFSUniStr255 forkName;
			OSStatus createRFErr = FSGetResourceForkName(&forkName);
			if (createRFErr == noErr) {
				createRFErr = FSCreateFork(&ref, forkName.length, forkName.unicode);
			}
		}

		rsrcForkFH = [NSFileHandle fileHandleForWritingToURL:rsrcForkURL error:outError];

		truncateResult = ftruncate(dataForkFH.fileDescriptor, totalForksSize);
		ImpPrintf(@"Initial truncate: %llu", totalForksSize);
		if (truncateResult != 0) {
			NSError *_Nonnull const truncationFailureError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Failed to extend data fork of file to total size of %llu bytes. This may mean you don't have enough space available to hold a file this big (%llu bytes data fork + %llu bytes resource fork = %@).", @""), totalForksSize, dataForkSize, rsrcForkSize, [bcf stringFromByteCount:totalForksSize] ] }];
			if (outError != NULL) {
				*outError = truncationFailureError;
				return false;
			}
		}

		//Should always succeed because we're shrinking it.
		truncateResult = ftruncate(dataForkFH.fileDescriptor, dataForkSize);
		ImpPrintf(@"Truncated data fork back to: %llu", dataForkSize);
		truncateResult = ftruncate(rsrcForkFH.fileDescriptor, rsrcForkSize);
		ImpPrintf(@"Truncated resource fork (%@) out to: %llu", rsrcForkURL.path, rsrcForkSize);
		ImpPrintf(@"“%@” has a data fork of %@ (%llu bytes), resource fork %@ (%llu bytes)", self.name, [bcf
																										 stringFromByteCount:dataForkSize], (unsigned long long)dataForkSize, [bcf stringFromByteCount:rsrcForkSize], (unsigned long long)rsrcForkSize);
		if (truncateResult != 0) {
			NSError *_Nonnull const truncationFailureError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Failed to extend resource fork of file to %llu bytes. This may mean you don't have enough space available to hold a file this big (%llu bytes data fork + %llu bytes resource fork = %@).", @""), rsrcForkSize, dataForkSize, rsrcForkSize, [bcf stringFromByteCount:totalForksSize] ] }];
			if (outError != NULL) {
				*outError = truncationFailureError;
				return false;
			}
		}
	}

	//This will be redundant if we went through the above, but is harmless to do again. And if we haven't gone through the above, then we haven't extended the data fork yet.
	truncateResult = ftruncate(dataForkFH.fileDescriptor, dataForkSize);
	if (truncateResult != 0) {
		NSError *_Nonnull const truncationFailureError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Failed to extend data fork of file to %llu bytes. This may mean you don't have enough space available to hold a file this big (%llu bytes data fork + %llu bytes resource fork = %@).", @""), dataForkSize, dataForkSize, rsrcForkSize, [bcf stringFromByteCount:totalForksSize] ] }];
		if (outError != NULL) {
			*outError = truncationFailureError;
			return false;
		}
	}

	//OK! Both forks are the lengths we need them to be. Time to start copying in data!

	__block bool allWritesSucceeded = true; //Defaults to true in case the fork is empty so we encounter no extents.
	__block NSError *_Nullable writeError = nil;
	[self.hfsVolume forEachExtentInFileWithID:self.catalogNodeID
		fork:ImpForkTypeData
		forkLogicalLength:dataForkSize
		startingWithExtentsRecord:fileRec->dataExtents
		readDataOrReturnError:outError
		block:^bool(NSData *_Nonnull const fileData, u_int64_t const logicalLength)
	{
		allWritesSucceeded = allWritesSucceeded && [dataForkFH writeData:fileData error:&writeError];
		return allWritesSucceeded;
	}];
	if (! allWritesSucceeded) {
		if (outError != NULL) {
			*outError = writeError;
			return false;
		}
	}
	//Now do that again, but for the resource fork.
	[self.hfsVolume forEachExtentInFileWithID:self.catalogNodeID
		fork:ImpForkTypeResource
		forkLogicalLength:rsrcForkSize
		startingWithExtentsRecord:fileRec->rsrcExtents
		readDataOrReturnError:outError
		block:^bool(NSData *_Nonnull const fileData, u_int64_t const logicalLength)
	{
		allWritesSucceeded = allWritesSucceeded && [rsrcForkFH writeData:fileData error:&writeError];
		return allWritesSucceeded;
	}];
	if (! allWritesSucceeded) {
		if (outError != NULL) {
			*outError = writeError;
			return false;
		}
	}

	//If we made it this far, we have copied the data and resource forks.
	bool const wroteData = true;
	//Next, copy over the file's metadata.
	bool wroteMetadata = false;
	//This part, unfortunately, has to use File Manager for maximum fidelity. We can translate the Locked bit to NSURLIsUserImmutableKey, but the Stationery bit has no modern API. Similarly, icon positions and other Finder info are not exposed in modern API. So, File Manager it is.
	//If CFURLGetFSRef fails, it might be because coreservicesd was not able to allocate another FSRef. (They're a shared resource for 64-bit apps, for reasons I don't remember the details of.) So fall back to doing things the NSURL way if we can't get an FSRef.
	FSRef ref;
	bool useFileManager = CFURLGetFSRef((__bridge CFURLRef)realWorldURL, &ref);
	if (useFileManager) {
		struct ExtendedFileInfo const *_Nonnull const sourceExtFinderInfo = (struct ExtendedFileInfo const *_Nonnull const)&(fileRec->finderInfo);
		struct ExtendedFileInfo swappedExtFinderInfo = {
			.reserved1 = {
				L(sourceExtFinderInfo->reserved1[0]),
				L(sourceExtFinderInfo->reserved1[1]),
				L(sourceExtFinderInfo->reserved1[2]),
				L(sourceExtFinderInfo->reserved1[3]),
			},
			.extendedFinderFlags = L(sourceExtFinderInfo->extendedFinderFlags),
			.reserved2 = L(sourceExtFinderInfo->reserved2),
			.putAwayFolderID = L(sourceExtFinderInfo->putAwayFolderID),
		};

		struct FSCatalogInfo catInfo = {
			.nodeFlags = L(fileRec->flags),
			.createDate = {
				.lowSeconds = L(fileRec->createDate),
			},
			.contentModDate = {
				.lowSeconds = L(fileRec->modifyDate),
			},
			//TODO: We should include textEncodingHint, based on whatever encoding was used to decode the file.
		};
		memcpy(&(catInfo.finderInfo), &swappedFinderInfo, sizeof(catInfo.finderInfo));
		memcpy(&(catInfo.extFinderInfo), &swappedExtFinderInfo, sizeof(catInfo.extFinderInfo));
		FSCatalogInfoBitmap const whichInfo = kFSCatInfoNodeFlags | kFSCatInfoCreateDate | kFSCatInfoContentMod | kFSCatInfoFinderInfo | kFSCatInfoFinderXInfo;
		OSStatus const err = FSSetCatalogInfo(&ref, whichInfo, &catInfo);
		if (err == noErr) {
			wroteMetadata = true;
		} else {
			NSError *_Nonnull const cantSetMetadataError = [NSError errorWithDomain:NSOSStatusErrorDomain code:err userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedString(@"Couldn't restore metadata for file using the File Manager", @"") }];
			if (outError != NULL) {
				*outError = cantSetMetadataError;
			}
		}
	}

	return wroteData && wroteMetadata;
}
- (bool) rehydrateFileAtRealWorldURL:(NSURL *_Nonnull const)realWorldURL error:(NSError *_Nullable *_Nonnull const)outError {
	struct HFSCatalogFile const *_Nonnull const fileRec = (struct HFSCatalogFile const *_Nonnull const)self.hfsFileCatalogRecordData.bytes;

	//TODO: This implementation will overwrite the destination file if it already exists. The client should probably check for that and prompt for confirmation…

	NSByteCountFormatter *_Nonnull const bcf = [NSByteCountFormatter new];
	off_t const dataForkSize = L(fileRec->dataLogicalSize);
	off_t const rsrcForkSize = L(fileRec->rsrcLogicalSize);
	//TODO: Probably should make sure both of these are non-negative and return a read error if we find a fork with a negative size.
	unsigned long long const totalForksSize = dataForkSize + rsrcForkSize;

	//First thing, create the file. We can set some metadata while we're at it, so do that.
	bool const isLocked = L(fileRec->flags) & kHFSFileLockedMask;
	struct FileInfo const *_Nonnull const sourceFinderInfo = (struct FileInfo const *_Nonnull const)&(fileRec->userInfo);
	struct FileInfo swappedFinderInfo = {
		.fileType = kFirstMagicBusyFiletype,//L(sourceFinderInfo->fileType),
		.fileCreator = L(sourceFinderInfo->fileCreator),
		.finderFlags = L(sourceFinderInfo->finderFlags),
		.location = {
			.h = L(sourceFinderInfo->location.h),
			.v = L(sourceFinderInfo->location.v),
		},
		.reservedField = L(sourceFinderInfo->reservedField),
	};
	struct ExtendedFileInfo const *_Nonnull const sourceExtFinderInfo = (struct ExtendedFileInfo const *_Nonnull const)&(fileRec->finderInfo);
	struct ExtendedFileInfo swappedExtFinderInfo = {
		.reserved1 = {
			L(sourceExtFinderInfo->reserved1[0]),
			L(sourceExtFinderInfo->reserved1[1]),
			L(sourceExtFinderInfo->reserved1[2]),
			L(sourceExtFinderInfo->reserved1[3]),
		},
		.extendedFinderFlags = L(sourceExtFinderInfo->extendedFinderFlags),
		.reserved2 = L(sourceExtFinderInfo->reserved2),
		.putAwayFolderID = L(sourceExtFinderInfo->putAwayFolderID),
	};

	struct FSCatalogInfo catInfo = {
		.nodeFlags = (L(fileRec->flags) & ~kFSNodeLockedMask) | kFSNodeResOpenMask | kFSNodeDataOpenMask | kFSNodeForkOpenMask,
		.createDate = {
			.lowSeconds = kMagicBusyCreationDate,//L(fileRec->createDate),
		},
		.contentModDate = {
			.lowSeconds = L(fileRec->modifyDate),
		},
		//TODO: We should include textEncodingHint, based on whatever encoding was used to decode the file.
	};
	memcpy(&(catInfo.finderInfo), &swappedFinderInfo, sizeof(catInfo.finderInfo));
	memcpy(&(catInfo.extFinderInfo), &swappedExtFinderInfo, sizeof(catInfo.extFinderInfo));
	FSCatalogInfoBitmap const whichInfo = kFSCatInfoNodeFlags | kFSCatInfoCreateDate | kFSCatInfoContentMod | kFSCatInfoFinderInfo | kFSCatInfoFinderXInfo;

	FSRef parentRef, ref;
	bool const gotParentRef = CFURLGetFSRef((__bridge CFURLRef)realWorldURL.URLByDeletingLastPathComponent, &parentRef);

	NSString *_Nonnull const name = realWorldURL.lastPathComponent;
	HFSUniStr255 name255 = { .length = name.length };
	if (name255.length > 255) name255.length = 255;
	[name getCharacters:name255.unicode range:(NSRange){ 0, name255.length }];

	OSStatus err;

	HFSUniStr255 dataForkName, rsrcForkName;
	err = FSGetDataForkName(&dataForkName);
	err = FSGetResourceForkName(&rsrcForkName);

	FSIORefNum dataForkRefnum = -1, rsrcForkRefnum = -1;
	//Create the resource fork first. If we can't do that, we can't rehydrate this file at all.
	//TODO: Maybe only do that if the dehydrated resource fork is non-empty. If there's no resource fork to be restored, we don't need to worry if the destination is data-fork-only.
	err = FSCreateFileAndOpenForkUnicode(&parentRef, name255.length, name255.unicode, whichInfo, &catInfo, rsrcForkName.length, rsrcForkName.unicode, fsWrPerm, &rsrcForkRefnum, &ref);
//	err = FSCreateFork(&ref, dataForkName.length, dataForkName.unicode);
	err = FSOpenFork(&ref, dataForkName.length, dataForkName.unicode, fsWrPerm, &dataForkRefnum);

	FSAllocateFork(dataForkRefnum, kFSAllocAllOrNothingMask | kFSAllocNoRoundUpMask, fsFromStart, /*positionOffset*/ 0, dataForkSize, /*actualCount*/ NULL);
	FSAllocateFork(rsrcForkRefnum, kFSAllocAllOrNothingMask | kFSAllocNoRoundUpMask, fsFromStart, /*positionOffset*/ 0, rsrcForkSize, /*actualCount*/ NULL);

	//OK! Both forks are the lengths we need them to be. Time to start copying in data!

	__block bool allWritesSucceeded = true; //Defaults to true in case the fork is empty so we encounter no extents.
	__block NSError *_Nullable writeError = nil;
	[self.hfsVolume forEachExtentInFileWithID:self.catalogNodeID
		fork:ImpForkTypeData
		forkLogicalLength:dataForkSize
		startingWithExtentsRecord:fileRec->dataExtents
		readDataOrReturnError:outError
		block:^bool(NSData *_Nonnull const fileData, u_int64_t const logicalLength)
	{
		OSStatus const dataWriteErr = FSWriteFork(dataForkRefnum, fsAtMark, /*positionOffset*/ 0, fileData.length, fileData.bytes, /*actualCount*/ NULL);
		allWritesSucceeded = allWritesSucceeded && (dataWriteErr == noErr);
		if (dataWriteErr != noErr) {
			//TODO: NSError
		}
		return allWritesSucceeded;
	}];
	if (! allWritesSucceeded) {
		if (outError != NULL) {
			*outError = writeError;
			return false;
		}
	}
	//Now do that again, but for the resource fork.
	[self.hfsVolume forEachExtentInFileWithID:self.catalogNodeID
		fork:ImpForkTypeResource
		forkLogicalLength:rsrcForkSize
		startingWithExtentsRecord:fileRec->rsrcExtents
		readDataOrReturnError:outError
		block:^bool(NSData *_Nonnull const fileData, u_int64_t const logicalLength)
	{
		OSStatus const rsrcWriteErr = FSWriteFork(rsrcForkRefnum, fsAtMark, /*positionOffset*/ 0, fileData.length, fileData.bytes, /*actualCount*/ NULL);
		allWritesSucceeded = allWritesSucceeded && (rsrcWriteErr == noErr);
		if (rsrcWriteErr != noErr) {
			//TODO: NSError
		}
		return allWritesSucceeded;
	}];
	if (! allWritesSucceeded) {
		if (outError != NULL) {
			*outError = writeError;
			return false;
		}
	}

	//If we made it this far, we have copied the data and resource forks.
	bool const wroteData = true;
	//Next, finish up the file's metadata by removing our busy markings.
	bool wroteMetadata = false;

	catInfo.createDate.lowSeconds = L(fileRec->createDate);
	swappedFinderInfo.fileType = L(fileRec->userInfo.fdType);
	memcpy(catInfo.finderInfo, &swappedFinderInfo, sizeof(catInfo.finderInfo));
	FSCatalogInfoBitmap const whichInfo2 = kFSCatInfoCreateDate | kFSCatInfoFinderInfo;
	err = FSSetCatalogInfo(&ref, whichInfo2, &catInfo);
	if (err == noErr) {
		wroteMetadata = true;
	} else {
		NSError *_Nonnull const cantSetMetadataError = [NSError errorWithDomain:NSOSStatusErrorDomain code:err userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedString(@"Couldn't restore metadata for file using the File Manager", @"") }];
		if (outError != NULL) {
			*outError = cantSetMetadataError;
		}
	}

	return wroteData && wroteMetadata;
}
- (bool) rehydrateFolderAtRealWorldURL:(NSURL *_Nonnull const)realWorldURL error:(NSError *_Nullable *_Nonnull const)outError {
	*outError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnsupportedSchemeError userInfo:@{ NSLocalizedDescriptionKey: @"Haven't implemented folder-hierarchy rehydration yet"}];
	return false;
}

@end
