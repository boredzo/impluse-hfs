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

typedef NS_ENUM(u_int64_t, ImpVolumeSizeThreshold) {
	//Rough estimates just for icon selection purposes.
	floppyMaxSize = 2 * 1024,
	cdMaxSize = 700 * 1048576,
	dvdMaxSize = 10ULL * 1048576ULL * 1024ULL,
};

@interface ImpDehydratedItem ()

- (bool) rehydrateFileAtRealWorldURL:(NSURL *_Nonnull const)realWorldURL error:(NSError *_Nullable *_Nonnull const)outError;
- (bool) rehydrateFolderAtRealWorldURL:(NSURL *_Nonnull const)realWorldURL error:(NSError *_Nullable *_Nonnull const)outError;

@property(nullable, nonatomic, readwrite, copy) NSArray <ImpDehydratedItem *> *children;

@end

static NSTimeInterval hfsEpochTISRD = -3061152000.0; //1904-01-01T00:00:00Z timeIntervalSinceReferenceDate

@implementation ImpDehydratedItem
{
	NSArray <NSString *> *_cachedPath;
	NSMutableArray <ImpDehydratedItem *> *_children;
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

		_parentFolderID = L(key->parentID);
		_type = _parentFolderID == kHFSRootParentID ? ImpDehydratedItemTypeVolume : ImpDehydratedItemTypeFolder;
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
	return self.type != ImpDehydratedItemTypeFile;
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

- (u_int64_t) logicalDataForkBytes {
	struct HFSCatalogFile const *_Nonnull const fileRec = self.hfsFileCatalogRecordData.bytes;
	return L(fileRec->dataLogicalSize);
}
- (u_int64_t) logicalResourceForkBytes {
	struct HFSCatalogFile const *_Nonnull const fileRec = self.hfsFileCatalogRecordData.bytes;
	return L(fileRec->rsrcLogicalSize);
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

	//Realistically, we have to use the File Manager.
	//The alternative is using NSURL and writing to resource forks as realWorldURL/..namedFork/rsrc. This doesn't work on APFS, for reasons unknown, and still wouldn't enable us to rehydrate certain metadata, such as the Locked checkbox.
	//So we're using deprecated API for want of an alternative. That means both methods that use such API need to silence the deprecated-API warnings.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

	//First thing, create the file. We can set some metadata while we're at it, so do that.
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

	NSString *_Nonnull const name = [realWorldURL.lastPathComponent stringByReplacingOccurrencesOfString:@":" withString:@"/"];
	HFSUniStr255 name255 = { .length = name.length };
	if (name255.length > 255) name255.length = 255;
	[name getCharacters:name255.unicode range:(NSRange){ 0, name255.length }];

	OSStatus err;

	HFSUniStr255 dataForkName, rsrcForkName;
	err = FSGetDataForkName(&dataForkName);
	if (err != noErr) {
		if (outError != NULL) {
			*outError = [NSError errorWithDomain:NSOSStatusErrorDomain code:err userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedString(@"Can't get name of data fork", @"")}];
		}
		return false;
	}
	err = FSGetResourceForkName(&rsrcForkName);
	if (err != noErr) {
		if (outError != NULL) {
			*outError = [NSError errorWithDomain:NSOSStatusErrorDomain code:err userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedString(@"Can't get name of resource fork", @"")}];
		}
		return false;
	}

	FSIORefNum dataForkRefnum = -1, rsrcForkRefnum = -1;
	//Create the resource fork first. If we can't do that, we can't rehydrate this file at all.
	//TODO: Maybe only do that if the dehydrated resource fork is non-empty. If there's no resource fork to be restored, we don't need to worry if the destination is data-fork-only.
	err = FSCreateFileAndOpenForkUnicode(&parentRef, name255.length, name255.unicode, whichInfo, &catInfo, rsrcForkName.length, rsrcForkName.unicode, fsWrPerm, &rsrcForkRefnum, &ref);
	if (err != noErr) {
		if (outError != NULL) {
			*outError = [NSError errorWithDomain:NSOSStatusErrorDomain code:err userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Can't create file “%@” and open its resource fork for writing", @""), name ]}];
		}
		return false;
	}
//	err = FSCreateFork(&ref, dataForkName.length, dataForkName.unicode);
	err = FSOpenFork(&ref, dataForkName.length, dataForkName.unicode, fsWrPerm, &dataForkRefnum);
	if (err != noErr) {
		if (outError != NULL) {
			*outError = [NSError errorWithDomain:NSOSStatusErrorDomain code:err userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Can't open data fork of file “%@” for writing", @""), name ]}];
		}
		return false;
	}

	err = FSAllocateFork(dataForkRefnum, kFSAllocAllOrNothingMask | kFSAllocNoRoundUpMask, fsFromStart, /*positionOffset*/ 0, dataForkSize, /*actualCount*/ NULL);
	if (err != noErr) {
		if (outError != NULL) {
			*outError = [NSError errorWithDomain:NSOSStatusErrorDomain code:err userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Can't extend data fork of file “%@” for writing", @""), name ]}];
		}
		return false;
	}
	err = FSAllocateFork(rsrcForkRefnum, kFSAllocAllOrNothingMask | kFSAllocNoRoundUpMask, fsFromStart, /*positionOffset*/ 0, rsrcForkSize, /*actualCount*/ NULL);
	if (err != noErr) {
		if (outError != NULL) {
			*outError = [NSError errorWithDomain:NSOSStatusErrorDomain code:err userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Can't extend resource fork of file “%@” for writing", @""), name ]}];
		}
		return false;
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
		OSStatus const dataWriteErr = FSWriteFork(dataForkRefnum, fsAtMark, noCacheMask, fileData.length, fileData.bytes, /*actualCount*/ NULL);
		allWritesSucceeded = allWritesSucceeded && (dataWriteErr == noErr);
		if (dataWriteErr != noErr) {
			writeError = [NSError errorWithDomain:NSOSStatusErrorDomain code:err userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Can't write to data fork of file “%@”", @""), name ]}];
		}
		return allWritesSucceeded;
	}];
	if (writeError != nil) {
		if (outError != NULL) {
			*outError = writeError;
		}
		return false;
	}
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
			writeError = [NSError errorWithDomain:NSOSStatusErrorDomain code:err userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Can't write to resource fork of file “%@”", @""), name ]}];
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

	catInfo.nodeFlags = L(fileRec->flags);
	catInfo.createDate.lowSeconds = L(fileRec->createDate);
	swappedFinderInfo.fileType = L(fileRec->userInfo.fdType);
	memcpy(catInfo.finderInfo, &swappedFinderInfo, sizeof(catInfo.finderInfo));
	FSCatalogInfoBitmap const whichInfo2 = kFSCatInfoCreateDate | kFSCatInfoContentMod | kFSCatInfoFinderInfo;
	err = FSSetCatalogInfo(&ref, whichInfo2, &catInfo);
	if (err == noErr) {
		wroteMetadata = true;
	} else {
		NSError *_Nonnull const cantSetMetadataError = [NSError errorWithDomain:NSOSStatusErrorDomain code:err userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedString(@"Couldn't restore metadata for file using the File Manager", @"") }];
		if (outError != NULL) {
			*outError = cantSetMetadataError;
		}
	}

#pragma clang diagnostic pop

	return wroteData && wroteMetadata;
}
- (bool) rehydrateFolderAtRealWorldURL:(NSURL *_Nonnull const)realWorldURL error:(NSError *_Nullable *_Nonnull const)outError {
	struct HFSCatalogFolder const *_Nonnull const folderRec = (struct HFSCatalogFolder const *_Nonnull const)self.hfsFolderCatalogRecordData.bytes;

	bool wroteChildren = true; //TODO: Come up with a better way to distinguish “wrote no children because the folder was empty” and “wrote no children because failure” (or, for that matter, “wrote some children but then failure”).
	bool wroteMetadata = false;

	//Realistically, we have to use the File Manager.
	//The alternative is using NSURL, which wouldn't enable us to rehydrate certain metadata, such as the Locked checkbox. (For files, it has even more problems, noted above.)
	//So we're using deprecated API for want of an alternative. That means both methods that use such API need to silence the deprecated-API warnings.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

	FSRef parentRef;
	if (CFURLGetFSRef((__bridge CFURLRef)realWorldURL.URLByDeletingLastPathComponent, &parentRef)) {
		NSString *_Nonnull const name = [realWorldURL.lastPathComponent stringByReplacingOccurrencesOfString:@":" withString:@"/"];
		HFSUniStr255 name255 = { .length = name.length };
		if (name255.length > 255) name255.length = 255;
		[name getCharacters:name255.unicode range:(NSRange){ 0, name255.length }];

		struct FolderInfo const *_Nonnull const sourceFinderInfo = (struct FolderInfo const *_Nonnull const)&(folderRec->userInfo);
		struct FolderInfo swappedFinderInfo = {
			.windowBounds = {
				.top = L(sourceFinderInfo->windowBounds.top),
				.left = L(sourceFinderInfo->windowBounds.left),
				.bottom = L(sourceFinderInfo->windowBounds.bottom),
				.right = L(sourceFinderInfo->windowBounds.right),
			},
			.finderFlags = L(sourceFinderInfo->finderFlags),
			.location = {
				.h = L(sourceFinderInfo->location.h),
				.v = L(sourceFinderInfo->location.v),
			},
			.reservedField = L(sourceFinderInfo->reservedField),
		};
		struct ExtendedFolderInfo const *_Nonnull const sourceExtFinderInfo = (struct ExtendedFolderInfo const *_Nonnull const)&(folderRec->finderInfo);
		struct ExtendedFolderInfo swappedExtFinderInfo = {
			.scrollPosition = {
				.h = L(sourceExtFinderInfo->scrollPosition.h),
				.v = L(sourceExtFinderInfo->scrollPosition.v),
			},
			.reserved1 = L(sourceExtFinderInfo->reserved1),
			.extendedFinderFlags = L(sourceExtFinderInfo->extendedFinderFlags),
			.reserved2 = L(sourceExtFinderInfo->reserved2),
			.putAwayFolderID = L(sourceExtFinderInfo->putAwayFolderID),
		};

		struct FSCatalogInfo catInfo = {
			.nodeFlags = (L(folderRec->flags) & ~kFSNodeLockedMask),
			.createDate = {
				.lowSeconds = kMagicBusyCreationDate,//L(fileRec->createDate),
			},
			.contentModDate = {
				.lowSeconds = L(folderRec->modifyDate),
			},
		};
		memcpy(&(catInfo.finderInfo), &swappedFinderInfo, sizeof(catInfo.finderInfo));
		memcpy(&(catInfo.extFinderInfo), &swappedExtFinderInfo, sizeof(catInfo.extFinderInfo));
		FSCatalogInfoBitmap const whichInfo = kFSCatInfoNodeFlags | kFSCatInfoCreateDate | kFSCatInfoContentMod | kFSCatInfoFinderInfo | kFSCatInfoFinderXInfo;

		OSStatus err;
		FSRef ref;
		UInt32 newDirID;
		err = FSCreateDirectoryUnicode(&parentRef, name255.length, name255.unicode, whichInfo, &catInfo, &ref, /*newSpec*/ NULL, &newDirID);
		if (err != noErr) {
			if (outError != NULL) {
				*outError = [NSError errorWithDomain:NSOSStatusErrorDomain code:err userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Can't create directory “%@”", @""), name ]}];
			}
			return false;
		}

		//TODO: I am once again asking myself to desiccate the knowledge of what encoding to use
		ImpTextEncodingConverter *_Nonnull const tec = [ImpTextEncodingConverter converterWithHFSTextEncoding:self.hfsTextEncoding];

		//For each item in the dehydrated directory, rehydrate it, too.
		//(Ugh, this might cost a ton of FSRefs.)
		@autoreleasepool {
			[self.hfsVolume.catalogBTree forEachItemInDirectory:self.catalogNodeID
			file:^bool(struct HFSCatalogKey const *_Nonnull const keyPtr, struct HFSCatalogFile const *_Nonnull const fileRec) {
				HFSCatalogNodeID const fileID = L(fileRec->fileID);
				ImpDehydratedItem *_Nonnull const dehydratedFile = [[ImpDehydratedItem alloc] initWithHFSVolume:self.hfsVolume catalogNodeID:fileID key:keyPtr fileRecord:fileRec];
				NSString *_Nonnull const filename = [[tec stringForPascalString:keyPtr->nodeName] stringByReplacingOccurrencesOfString:@"/" withString:@":"];
				NSURL *_Nonnull const fileURL = [realWorldURL URLByAppendingPathComponent:filename isDirectory:false];
				ImpPrintf(@"Rehydrating descendant 📄 “%@”", filename);
				bool const rehydrated = [dehydratedFile rehydrateFileAtRealWorldURL:fileURL error:outError];
				if (! rehydrated) {
					ImpPrintf(@"%@ in rehydrating descendant 📄 “%@”", rehydrated ? @"Success" : @"Failure", filename);
				}
				return rehydrated;
			}
			folder:^bool(struct HFSCatalogKey const *_Nonnull const keyPtr, struct HFSCatalogFolder const *_Nonnull const folderRec) {
				ImpDehydratedItem *_Nonnull const dehydratedFolder = [[ImpDehydratedItem alloc] initWithHFSVolume:self.hfsVolume catalogNodeID:L(folderRec->folderID) key:keyPtr folderRecord:folderRec];
				NSString *_Nonnull const folderName = [[tec stringForPascalString:keyPtr->nodeName] stringByReplacingOccurrencesOfString:@"/" withString:@":"];
				NSURL *_Nonnull const folderURL = [realWorldURL URLByAppendingPathComponent:folderName isDirectory:true];
				ImpPrintf(@"Rehydrating descendant 📁 “%@”", folderName);
				bool const rehydrated = [dehydratedFolder rehydrateFolderAtRealWorldURL:folderURL error:outError];
				ImpPrintf(@"%@ in rehydrating descendant 📁 “%@”", rehydrated ? @"Success" : @"Failure", folderName);
				return rehydrated;
			}];
		}

		catInfo.createDate.lowSeconds = L(folderRec->createDate);
		FSCatalogInfoBitmap const whichInfo2 = kFSCatInfoCreateDate | kFSCatInfoContentMod;
		err = FSSetCatalogInfo(&ref, whichInfo2, &catInfo);
		if (err == noErr) {
			wroteMetadata = true;
		} else {
			if (outError != NULL) {
				*outError = [NSError errorWithDomain:NSOSStatusErrorDomain code:err userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Can't set metadata of directory “%@”", @""), name ]}];
			}
			return false;
		}
	}

#pragma clang diagnostic pop

	return (wroteChildren && wroteMetadata);
}

#pragma mark Directory trees

///Returns a string that represents this item when printed to the console.
- (NSString *_Nonnull) iconEmojiString {
	switch (self.type) {
		case ImpDehydratedItemTypeFile:
			return @"📄";
		case ImpDehydratedItemTypeFolder:
			return @"📁";
		case ImpDehydratedItemTypeVolume:
			if (self.hfsVolume.totalSizeInBytes <= floppyMaxSize) {
				return @"💾";
			} else if (self.hfsVolume.totalSizeInBytes <= cdMaxSize) {
				return @"💿";
			} else if (self.hfsVolume.totalSizeInBytes <= dvdMaxSize) {
				return @"📀";
			} else {
				return @"🗄";
			}
	}
	return @"❓";
}
///Returns a string that identifies a macOS icon that can be used to represent this icon in a Mac GUI. Pass this string to +[NSImage iconForFileType:].
- (NSString *_Nonnull) iconTypeString {
	switch (self.type) {
		case ImpDehydratedItemTypeFile:
			//TODO: Maybe use the generic application icon if this item has file type 'APPL'? Or, maybe just pass this file's type directly in here?
			return NSFileTypeForHFSTypeCode(kGenericDocumentIcon);
		case ImpDehydratedItemTypeFolder:
			return NSFileTypeForHFSTypeCode(kGenericFolderIcon);
		case ImpDehydratedItemTypeVolume:
			if (self.hfsVolume.totalSizeInBytes <= floppyMaxSize) {
				return NSFileTypeForHFSTypeCode(kGenericFloppyIcon);
			} else if (self.hfsVolume.totalSizeInBytes <= cdMaxSize) {
				return NSFileTypeForHFSTypeCode(kGenericCDROMIcon);
			} else if (self.hfsVolume.totalSizeInBytes <= dvdMaxSize) {
				//Unlike emoji, there's no DVD icon.
				return NSFileTypeForHFSTypeCode(kGenericCDROMIcon);
			} else {
				return NSFileTypeForHFSTypeCode(kGenericHardDiskIcon);
			}
	}
	return NSFileTypeForHFSTypeCode(kUnknownFSObjectIcon);
}

- (void) _walkBreadthFirstAtDepth:(NSUInteger)depth block:(void (^_Nonnull const)(NSUInteger const depth, ImpDehydratedItem *_Nullable const item))block
{
	block(depth, self);
	++depth;

	NSMutableArray <ImpDehydratedItem *> *_Nonnull const subfolders = [NSMutableArray arrayWithCapacity:self.countOfChildren];
	for (ImpDehydratedItem *_Nonnull const item in self.children) {
		block(depth, item);
		if (item.isDirectory) {
			[subfolders addObject:item];
		}
	}

	block(depth, nil);

	for (ImpDehydratedItem *_Nonnull const item in subfolders) {
		[item _walkBreadthFirstAtDepth:depth block:block];
	}
}

///Call the block for each item in the tree. Calls the block with nil for the item at the end of each directory.
- (void) walkBreadthFirst:(void (^_Nonnull const)(NSUInteger const depth, ImpDehydratedItem *_Nullable const item))block {
	[self _walkBreadthFirstAtDepth:0 block:block];
}

+ (instancetype _Nonnull) rootDirectoryOfHFSVolume:(ImpHFSVolume *_Nonnull const)hfsVol {

	ImpBTreeFile *_Nonnull const catalog = hfsVol.catalogBTree;

	NSUInteger const totalNumItems = hfsVol.numberOfFiles + hfsVol.numberOfFolders;
	NSMutableDictionary <NSNumber *, ImpDehydratedItem *> *_Nonnull const dehydratedFolders = [NSMutableDictionary dictionaryWithCapacity:hfsVol.numberOfFolders];
	//This is totally a wild guess of a heuristic.
	NSMutableArray <ImpDehydratedItem *> *_Nonnull const itemsThatNeedToBeAddedToTheirParents = [NSMutableArray arrayWithCapacity:totalNumItems / 2];

	__block ImpDehydratedItem *_Nullable rootItem = nil;

	[catalog walkLeafNodes:^bool(ImpBTreeNode *const  _Nonnull node) {
		[node forEachCatalogRecord_file:^(const struct HFSCatalogKey *const  _Nonnull catalogKeyPtr, const struct HFSCatalogFile *const _Nonnull fileRec) {
			ImpDehydratedItem *_Nonnull const dehydratedFile = [[ImpDehydratedItem alloc] initWithHFSVolume:hfsVol catalogNodeID:L(fileRec->fileID) key:catalogKeyPtr fileRecord:fileRec];

			ImpDehydratedItem *_Nullable const parent = dehydratedFolders[@(L(catalogKeyPtr->parentID))];
			if (parent != nil) {
				[parent addChildrenObject:dehydratedFile];
			} else {
				[itemsThatNeedToBeAddedToTheirParents addObject:dehydratedFile];
			}
		} folder:^(const struct HFSCatalogKey *const  _Nonnull catalogKeyPtr, const struct HFSCatalogFolder *const _Nonnull folderRec) {
			ImpDehydratedItem *_Nonnull const dehydratedFolder = [[ImpDehydratedItem alloc] initWithHFSVolume:hfsVol catalogNodeID:L(folderRec->folderID) key:catalogKeyPtr folderRecord:folderRec];
			dehydratedFolder->_children = [NSMutableArray arrayWithCapacity:L(folderRec->valence)];

			dehydratedFolders[@(dehydratedFolder.catalogNodeID)] = dehydratedFolder;

			HFSCatalogNodeID const parentID = L(catalogKeyPtr->parentID);
			if (parentID == kHFSRootParentID) {
				rootItem = dehydratedFolder;
			} else {
				ImpDehydratedItem *_Nullable const parent = dehydratedFolders[@(parentID)];
				if (parent != nil) {
					[parent addChildrenObject:dehydratedFolder];
				} else {
					[itemsThatNeedToBeAddedToTheirParents addObject:dehydratedFolder];
				}
			}
		} thread:^(const struct HFSCatalogKey *const  _Nonnull catalogKeyPtr, const struct HFSCatalogThread *const _Nonnull threadRec) {
			//Not sure we have anything to do for threads?
		}];
		return true;
	}];


	for (ImpDehydratedItem *_Nonnull const item in itemsThatNeedToBeAddedToTheirParents) {
		[dehydratedFolders[@(item.parentFolderID)] addChildrenObject:item];
	}

	return dehydratedFolders[@(kHFSRootFolderID)];
}

- (void) printDirectoryHierarchy {
	NSMutableString *_Nonnull const spaces = [
		@" " @" " @" " @" "
		@" " @" " @" " @" "
		@" " @" " @" " @" "
		@" " @" " @" " @" "
		mutableCopy];
	NSString *_Nonnull(^_Nonnull const indentWithDepth)(NSUInteger const depth) = ^NSString *_Nonnull(NSUInteger const depth) {
		if (depth > spaces.length) {
			NSRange extendRange = { spaces.length, depth - spaces.length };
			for (NSUInteger i = extendRange.location; i < depth; ++i) {
				[spaces appendString:@" "];
			}
		}
		return [spaces substringToIndex:depth];
	};

	ImpDehydratedItem *_Nonnull const rootDirectory = self;
	ImpPrintf(@"Name   \tData size\tRsrc size\tTotal size");
	ImpPrintf(@"═══════\t═════════\t═════════\t═════════");
	NSNumberFormatter *_Nonnull const fmtr = [NSNumberFormatter new];
	fmtr.numberStyle = NSNumberFormatterDecimalStyle;
	fmtr.hasThousandSeparators = true;

	__block u_int64_t totalDF = 0, totalRF = 0, totalTotal = 0;

	__block NSUInteger lastKnownDepth = 0;
	[rootDirectory walkBreadthFirst:^(NSUInteger const depth, ImpDehydratedItem *_Nonnull const item) {
		if (item == nil) {
			ImpPrintf(@"");
			return;
		}

		lastKnownDepth = depth;
		switch (item.type) {
			case ImpDehydratedItemTypeFile: {
				u_int64_t const sizeDF = item.logicalDataForkBytes, sizeRF = item.logicalResourceForkBytes, sizeTotal = sizeDF + sizeRF;
				totalDF += sizeDF;
				totalRF += sizeRF;
				totalTotal += sizeTotal;
				ImpPrintf(@"%@%@ %@\t%9@\t%9@\t%9@", indentWithDepth(depth), item.iconEmojiString, item.name, [fmtr stringFromNumber:@(sizeDF)], [fmtr stringFromNumber:@(sizeRF)], [fmtr stringFromNumber:@(sizeTotal)]);
				break;
			}
			case ImpDehydratedItemTypeFolder:
			case ImpDehydratedItemTypeVolume:
				ImpPrintf(@"%@%@ %@ contains %u items", indentWithDepth(depth), item.iconEmojiString, item.name, [item countOfChildren]);
				break;
			default:
				ImpPrintf(@"%@%@ %@", indentWithDepth(depth), item.iconEmojiString, item.name);
				break;
		}
		if (depth != lastKnownDepth) ImpPrintf(@"");
	}];
	ImpPrintf(@"═══════\t═════════\t═════════\t═════════");
	ImpPrintf(@"%@\t%9@\t%9@\t%9@", @"Total", [fmtr stringFromNumber:@(totalDF)], [fmtr stringFromNumber:@(totalRF)], [fmtr stringFromNumber:@(totalTotal)]);

	//Lastly, report the sizes of the catalog and extents files.
	bool const includeCatAndExt = false;
	if (includeCatAndExt) {
		ImpPrintf(@"═══════\t═════════\t═════════\t═════════");
		{
			u_int64_t const sizeDF = self.hfsVolume.catalogSizeInBytes, sizeRF = 0, sizeTotal = sizeDF + sizeRF;
			totalDF += sizeDF;
			totalRF += sizeRF;
			totalTotal += sizeTotal;
			ImpPrintf(@"%@ %@\t%9@\t%9@\t%9@", @"🗃", @"Catalog", [fmtr stringFromNumber:@(sizeDF)], [fmtr stringFromNumber:@(sizeRF)], [fmtr stringFromNumber:@(sizeTotal)]);
		}
		{
			u_int64_t const sizeDF = self.hfsVolume.extentsOverflowSizeInBytes, sizeRF = 0, sizeTotal = sizeDF + sizeRF;
			totalDF += sizeDF;
			totalRF += sizeRF;
			totalTotal += sizeTotal;
			ImpPrintf(@"%@ %@\t%9@\t%9@\t%9@", @"🗃", @"Extents", [fmtr stringFromNumber:@(sizeDF)], [fmtr stringFromNumber:@(sizeRF)], [fmtr stringFromNumber:@(sizeTotal)]);
		}
		ImpPrintf(@"═══════\t═════════\t═════════\t═════════");
		ImpPrintf(@"%@\t%9@\t%9@\t%9@", @"Total", [fmtr stringFromNumber:@(totalDF)], [fmtr stringFromNumber:@(totalRF)], [fmtr stringFromNumber:@(totalTotal)]);
	}
}
- (NSUInteger) countOfChildren {
	return _children.count;
}
- (void) addChildrenObject:(ImpDehydratedItem *_Nonnull const)object {
	[_children addObject:object];
}

@end
