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

- (NSUInteger) hash {
	NSUInteger hash = self.name.hash << 5;
	hash |= (self.path.count & 0xf) << 1;
	hash |= self.isDirectory;
	return hash;
}
- (BOOL) isEqual:(id)object {
	if (self == object)
		return true;
	if (! [object isKindOfClass:[ImpDehydratedItem class]])
		return false;
	return [self.path isEqualToArray:((ImpDehydratedItem *)object).path];
}

- (bool) isDirectory {
	return self.type == ImpDehydratedItemTypeFolder;
}

- (HFSCatalogNodeID) parentFolderID {
	struct HFSCatalogKey const *_Nonnull const catalogKey = (struct HFSCatalogKey const *_Nonnull const)(self.hfsCatalogKeyData.bytes);
	return L(catalogKey->parentID);
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
		OSStatus const dataWriteErr = FSWriteFork(dataForkRefnum, fsAtMark, noCacheMask, fileData.length, fileData.bytes, /*actualCount*/ NULL);
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
		OSStatus const rsrcWriteErr = FSWriteFork(rsrcForkRefnum, fsAtMark, noCacheMask, logicalLength, fileData.bytes, /*actualCount*/ NULL);
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
