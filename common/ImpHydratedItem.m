//
//  ImpHydratedItem.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2024-03-10.
//

#import "ImpHydratedItem.h"

#import <sys/stat.h>
#import <sys/xattr.h>

#import "ImpTextEncodingConverter.h"
#import "ImpSizeUtilities.h"

@interface ImpHydratedItem ()

- (instancetype _Nullable) initWithRealWorldURL:(NSURL *_Nonnull const)fileURL;

@property(readonly, nonatomic, copy) NSString *_Nonnull emojiIcon;

@end

static int64_t hfsEpochTISRD = -3061152000; //1904-01-01T00:00:00Z timeIntervalSinceReferenceDate

static NSUInteger originalItemCount = 0;

static struct HFSUniStr255 dataForkName = { .length = 0 };
static struct HFSUniStr255 resourceForkName = { .length = 8, .unicode = { 'R', 'E', 'S', 'O', 'U', 'R', 'C', 'E' } };

@implementation ImpHydratedItem

+ (void) initialize {
	FSGetDataForkName(&dataForkName);
	FSGetResourceForkName(&resourceForkName);
}

+ (ImpItemClassification) classifyRealWorldURL:(NSURL *_Nonnull const)fileURL error:(out NSError *_Nullable *_Nullable const)outError {
	struct stat sb;
	int const stat_result = lstat(fileURL.fileSystemRepresentation, &sb);
	if (stat_result < 0) {
		NSError *_Nonnull const statError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: @(strerror(errno)) }];
		if (outError != NULL) {
			*outError = statError;
		}
		return ImpItemClassificationNonexistent;
	}

	//See definition of ImpItemClassification in the header.
	mode_t const itemKind = sb.st_mode & S_IFMT;
	switch (itemKind) {
		case S_IFREG:
		case S_IFDIR:
			return itemKind;
		case S_IFLNK: {
			struct stat orig_sb;
			int const orig_stat_result = stat(fileURL.fileSystemRepresentation, &sb);
			if (orig_stat_result < 0) {
				NSError *_Nonnull const statError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: @(strerror(errno)) }];
				if (outError != NULL) {
					*outError = statError;
				}
				return ImpItemClassificationNonexistent;
			}
			mode_t const origItemKind = orig_sb.st_mode & S_IFMT;
			switch (origItemKind) {
				case S_IFREG:
				case S_IFDIR:
					if (orig_sb.st_dev == sb.st_dev) {
						return origItemKind;
					} else {
						return ImpItemClassificationSymbolicLinkDifficult;
					}

				default:
					return S_IFMT;
			}
		}

		default:
			return S_IFMT;
	}
}

+ (instancetype _Nullable) itemWithRealWorldURL:(NSURL *_Nonnull const)fileURL error:(out NSError *_Nullable *_Nullable const)outError {
	ImpItemClassification const classification = [self classifyRealWorldURL:fileURL error:outError];
	switch (classification) {
		case ImpItemClassificationRegularFile:
			return [[ImpHydratedFile alloc] initWithRealWorldURL:fileURL];
		case ImpItemClassificationFolder:
			return [[ImpHydratedFolder alloc] initWithRealWorldURL:fileURL];

		default: {
			NSError *_Nonnull const unusableItemError = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOTSUP userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Can't dehydrate item at %@", fileURL.path] }];
			if (outError != NULL) {
				*outError = unusableItemError;
			}
			return nil;
		}
	}
}

- (instancetype _Nullable)initWithRealWorldURL:(NSURL *_Nonnull const)fileURL {
	NSParameterAssert(! [self isMemberOfClass:[ImpHydratedItem class]]);

	if ((self = [super init])) {
		_realWorldURL = [fileURL copy];
		_name = _realWorldURL.lastPathComponent;
	}
	return self;
}

+ (instancetype _Nonnull) itemWithOriginalFolder {
	return [[ImpHydratedFolder alloc] init];
}

- (NSString *_Nonnull const) emojiIcon {
	static NSString *_Nonnull const defaultEmojiIcon = @"📇";
	return defaultEmojiIcon;
}

- (NSString *_Nonnull const) description {
	NSString *_Nonnull const quotedName = self.name ? [NSString stringWithFormat:@"“%@”", self.name] : @"(unnamed)";
	return [NSString stringWithFormat:@"<%@ %p %@ #%u %@>", self.class, self, self.emojiIcon, self.assignedItemID, quotedName];
}

#pragma mark Collection necessities

- (id _Nonnull) copyWithZone:(NSZone *_Nullable)zone {
	return (__bridge id)(__bridge_retained CFTypeRef)self;
}

- (NSUInteger) hash {
	bool const isOriginalItem = _originalItemNumber;
	struct stat sb = { 0 };
	lstat(self.realWorldURL.fileSystemRepresentation, &sb);
	NSUInteger const inodeNum = sb.st_ino << 9;
	NSUInteger const origItemNum = _originalItemNumber << 1;
	NSUInteger const isOrigItemBit = isOriginalItem << 0;
	return inodeNum ^ origItemNum ^ isOrigItemBit;
}

- (BOOL) isEqual:(id _Nonnull)object {
	ImpHydratedItem *_Nonnull const otherItem = object;
	//Original items are unique and therefore never equal to any other item.
	if (self.realWorldURL == nil) {
		return false;
	}
	if (otherItem.realWorldURL == nil) {
		return false;
	}

	//Try to determine whether these are the same real file.
	struct stat selfSB, otherSB;
	int const selfStatResult = lstat(self.realWorldURL.fileSystemRepresentation, &selfSB);
	int const selfStatErrno = errno;
	int const otherStatResult = lstat(otherItem.realWorldURL.fileSystemRepresentation, &otherSB);
	int const otherStatErrno = errno;
	if (selfStatResult != otherStatResult) {
		return false;
	}
	if (selfStatErrno != otherStatErrno) {
		return false;
	}
	if (selfStatResult != 0) {
		return [self.realWorldURL isEqual:otherItem.realWorldURL];
	}

	return selfSB.st_dev == otherSB.st_dev && selfSB.st_ino == otherSB.st_ino;
}

#pragma mark Name encoding

- (bool) checkItemName:(out NSError *_Nullable *_Nullable const)outError {
	Str31 temp;
	return [self.textEncodingConverter convertString:self.name toHFSItemName:temp error:outError];
}

- (bool) checkVolumeName:(out NSError *_Nullable *_Nullable const)outError {
	Str27 temp;
	return [self.textEncodingConverter convertString:self.name toHFSVolumeName:temp error:outError];
}

///Note: Implicitly limits to Str31.
- (void) convertName:(NSString *_Nonnull const)name toHFSItemName:(StringPtr _Nonnull const)pStringBuf {
	[self.textEncodingConverter convertString:name toHFSItemName:pStringBuf error:NULL];
}

#pragma mark Date utilities

+ (u_int32_t) hfsDateForDate:(NSDate *_Nonnull const)dateToConvert timeZoneOffset:(long)offsetSeconds {
	return (u_int32_t)((dateToConvert.timeIntervalSinceReferenceDate - hfsEpochTISRD) - offsetSeconds);
}

- (u_int32_t) hfsDateForTimespec:(struct timespec const *_Nonnull const)dateToConvert {
	//Converting to NSDate here is problematic because it gets floating-point involved and can lose precision, but we need to do the time zone conversion.
	int64_t const unixDateSec = dateToConvert->tv_sec;
	int64_t const unixDateNSec = dateToConvert->tv_nsec;
	double const unixDate = unixDateSec + ((double)unixDateNSec) / 1e9;
	NSDate *_Nonnull const date = [NSDate dateWithTimeIntervalSince1970:unixDate];
	return [[self class] hfsDateForDate:date timeZoneOffset:[[NSTimeZone localTimeZone] secondsFromGMTForDate:date]];
}

#pragma mark Catalog record writing

- (void) fillOutHFSCatalogKey:(NSMutableData *_Nonnull const)keyData
	parentID:(HFSCatalogNodeID)parentID
	nodeName:(NSString *_Nonnull const)nodeName
{
	struct HFSCatalogKey *_Nonnull const keyPtr = keyData.mutableBytes;
	S(keyPtr->parentID, parentID);
	NSParameterAssert(self.textEncodingConverter != nil);
	[self convertName:nodeName toHFSItemName:keyPtr->nodeName];
	u_int8_t const keyLength = sizeof(keyPtr->parentID) + sizeof(keyPtr->nodeName[0]) * (1 + keyPtr->nodeName[0]);
	S(keyPtr->keyLength, keyLength);
	keyData.length = keyLength + sizeof(keyPtr->keyLength);
	NSParameterAssert(keyData.length >= kHFSCatalogKeyMinimumLength);
	NSParameterAssert(keyData.length <= kHFSCatalogKeyMaximumLength);
}

///Utility for subclasses to fill out a catalog key for a thread record.
- (void) fillOutHFSCatalogThreadKey:(NSMutableData *_Nonnull const)keyData
	ownID:(HFSCatalogNodeID)ownID
{
	struct HFSCatalogKey *_Nonnull const keyPtr = keyData.mutableBytes;
	S(keyPtr->parentID, ownID);
	keyPtr->nodeName[0] = 0;
	u_int8_t const keyLength = sizeof(keyPtr->parentID) + sizeof(keyPtr->nodeName[0]) * (1 + keyPtr->nodeName[0]);
	S(keyPtr->keyLength, keyLength);
	keyData.length = keyLength + sizeof(keyPtr->keyLength);
	NSParameterAssert(keyData.length >= kHFSCatalogKeyMinimumLength);
	NSParameterAssert(keyData.length <= kHFSCatalogKeyMaximumLength);
}

- (void) fillOutHFSPlusCatalogKey:(NSMutableData *_Nonnull const)keyData
	parentID:(HFSCatalogNodeID)parentID
	nodeName:(NSString *_Nonnull const)nodeName
{
	struct HFSPlusCatalogKey *_Nonnull const keyPtr = keyData.mutableBytes;
	S(keyPtr->parentID, parentID);
	NSParameterAssert(self.textEncodingConverter != nil);
	[self.textEncodingConverter convertString:nodeName toHFSUniStr255:&keyPtr->nodeName];
	u_int16_t const keyLength = sizeof(keyPtr->parentID) + sizeof(L(keyPtr->nodeName.length)) * (1 + L(keyPtr->nodeName.length));
	S(keyPtr->keyLength, keyLength);
	keyData.length = keyLength + sizeof(keyPtr->keyLength);
	NSParameterAssert(keyData.length >= kHFSPlusCatalogKeyMinimumLength);
	NSParameterAssert(keyData.length <= kHFSPlusCatalogKeyMaximumLength);
}

- (void) fillOutHFSPlusCatalogThreadKey:(NSMutableData *_Nonnull const)keyData
	ownID:(HFSCatalogNodeID)ownID
{
	struct HFSPlusCatalogKey *_Nonnull const keyPtr = keyData.mutableBytes;
	S(keyPtr->parentID, ownID);
	keyPtr->nodeName.length = 0;
	u_int16_t const keyLength = sizeof(keyPtr->parentID) + sizeof(L(keyPtr->nodeName.length)) * (1 + L(keyPtr->nodeName.length));
	S(keyPtr->keyLength, keyLength);
	keyData.length = keyLength + sizeof(keyPtr->keyLength);
	NSParameterAssert(keyData.length >= kHFSPlusCatalogKeyMinimumLength);
	NSParameterAssert(keyData.length <= kHFSPlusCatalogKeyMaximumLength);
}

#pragma mark Real-world access

- (int) permissionsForOpening {
	NSAssert(false, @"Method %s not implemented by subclass", sel_getName(_cmd));
	return 0;
}

///Open the reading file handle if it isn't already, and return it.
- (NSFileHandle *_Nonnull const) openReadingFileHandle {
	NSFileHandle *_Nullable readFH = self.readingFileHandle;
	if (readFH == nil) {
		int const readFD = open(self.realWorldURL.fileSystemRepresentation, self.permissionsForOpening, 0444);
		readFH = [[NSFileHandle alloc] initWithFileDescriptor:readFD closeOnDealloc:true];
		self.readingFileHandle = readFH;
	}
	return readFH;
}

///Close the reading file handle if it exists, and destroy it.
- (void) closeReadingFileHandle {
	NSFileHandle *_Nullable readFH = self.readingFileHandle;
	if (readFH != nil) {
		[readFH closeFile];
		readFH = nil;
	}
}

#pragma mark Hierarchy flattening

- (void) recursivelyAddItemsToArray:(NSMutableArray <ImpHydratedItem *> *_Nonnull const)array {
	NSAssert(false, @"%@ is an instance of an abstract class; it cannot add anything to anything", self);
}

@end

@implementation ImpHydratedFolder
{
	NSArray <ImpHydratedItem *> *_Nullable _contentsCache;
}

- (instancetype _Nonnull) init {
	if ((self = [super init])) {
		++originalItemCount;
		_originalItemNumber = originalItemCount;
	}
	return self;
}

- (NSString *_Nonnull const) emojiIcon {
	static NSString *_Nonnull const folderEmojiIcon = @"📁";
	return folderEmojiIcon;
}

#pragma mark Real-world access

- (int) permissionsForOpening {
	return O_RDONLY | O_DIRECTORY;
}

#pragma mark Catalog records

- (bool) fillOutHFSCatalogKey:(NSMutableData *_Nonnull const)keyData
	hfsCatalogFolder:(NSMutableData *_Nonnull const)payloadData
	error:(out NSError *_Nullable *_Nullable const)outError
{
	ImpHydratedFolder *_Nullable const parentFolder = self.parentFolder;
	HFSCatalogNodeID const parentID = parentFolder != nil ? parentFolder.assignedItemID : kHFSRootParentID;
	[self fillOutHFSCatalogKey:keyData
		parentID:parentID
		nodeName:self.name];

	struct HFSCatalogFolder *_Nonnull const folderRecPtr = payloadData.mutableBytes;
	S(folderRecPtr->recordType, kHFSFolderRecord);

	struct stat dirSB = { 0 };
	struct DXInfo extInfo = { 0 };

	if (self.realWorldURL == nil) {
		//This is an original item—probably the root directory. Populate the stat block as best we can.
		dirSB.st_flags = 0;
		struct timespec now;
		clock_gettime(CLOCK_REALTIME, &now);
		memcpy(&dirSB.st_ctimespec, &now, sizeof(dirSB.st_ctimespec));
		memcpy(&dirSB.st_mtimespec, &now, sizeof(dirSB.st_mtimespec));
		memcpy(&dirSB.st_atimespec, &now, sizeof(dirSB.st_atimespec));
	} else {
		NSFileHandle *_Nonnull const readFH = [self openReadingFileHandle];
		int const fd = readFH.fileDescriptor;
		if (fd < 0) {
			int const dirStatErrno = errno;
			NSError *_Nonnull const dirStatError = [NSError errorWithDomain:NSPOSIXErrorDomain code:dirStatErrno userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Couldn't open folder to catalog it: %@", self.realWorldURL.path] }];
			self.accessError = dirStatError;
			if (outError != NULL) {
				*outError = dirStatError;
			}
			return false;
		}

		int const dirStatResult = fstat(fd, &dirSB);
		if (dirStatResult < 0) {
			int const dirStatErrno = errno;
			NSError *_Nonnull const dirStatError = [NSError errorWithDomain:NSPOSIXErrorDomain code:dirStatErrno userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failure getting vital statistics for folder %@", self.realWorldURL.path] }];
			self.accessError = dirStatError;
			if (outError != NULL) {
				*outError = dirStatError;
			}
			return false;
		}

		NSMutableData *_Nonnull const finderInfoData = [NSMutableData dataWithLength:sizeof(folderRecPtr->userInfo) + sizeof(folderRecPtr->finderInfo)];
		ssize_t const finderInfoLength = fgetxattr(fd, "com.apple.FinderInfo", finderInfoData.mutableBytes, finderInfoData.length, /*position*/ 0, /*options*/ 0);
		if (finderInfoLength < 0) {
			int const getxattrErrno = errno;
			NSError *_Nonnull const getxattrError = [NSError errorWithDomain:NSPOSIXErrorDomain code:getxattrErrno userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failure getting Finder info for item %@", self.realWorldURL.path] }];
			self.accessError = getxattrError;
			if (outError != NULL) {
				*outError = getxattrError;
			}
			return false;
		}
		[finderInfoData getBytes:&(folderRecPtr->userInfo) range:(NSRange){ 0, sizeof(folderRecPtr->userInfo) }];
		[finderInfoData getBytes:&(extInfo) range:(NSRange){ sizeof(folderRecPtr->userInfo), sizeof(extInfo) }];
	}

	UInt8 const lockedMask = ((dirSB.st_flags & UF_IMMUTABLE) ? kHFSFileLockedMask : 0);
	//We always create a thread record, so always set this to true.
	UInt8 const hasThreadMask = kHFSThreadExistsMask;
	S(folderRecPtr->flags, lockedMask | hasThreadMask);
	NSUInteger const numChildren = self.contents.count;
	if (numChildren > UINT16_MAX) {
		//TODO: Is this the right error code? Not that it matters, but what does File Manager return when trying to create a 32,768th file inside a folder on HFS? (Or 65,536th given the type, but https://web.archive.org/web/20020803105007/http://docs.info.apple.com/article.html?artnum=8647 says the limit is 32,767.)
		NSError *_Nonnull const tooManyChildrenError = [NSError errorWithDomain:NSOSStatusErrorDomain code:dirFulErr userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Folder %@ has more items (%lu) than an HFS folder can hold", self.realWorldURL.path, numChildren] }];
		self.accessError = tooManyChildrenError;
		if (outError != NULL) {
			*outError = tooManyChildrenError;
		}
		return false;
	}
	S(folderRecPtr->valence, (u_int16_t)numChildren);

	S(folderRecPtr->folderID, self.assignedItemID);
	S(folderRecPtr->createDate, [self hfsDateForTimespec:&dirSB.st_ctimespec]);
	S(folderRecPtr->modifyDate, [self hfsDateForTimespec:&dirSB.st_mtimespec]);
	S(folderRecPtr->backupDate, 0);

	ScriptCode script;
	OSStatus err = RevertTextEncodingToScriptInfo(self.textEncodingConverter.hfsTextEncoding, &script, /*outLanguageID*/ NULL, /*outFontName*/ NULL);
	if (err != noErr) {
		NSError *_Nonnull const noScriptCodeError = [NSError errorWithDomain:NSOSStatusErrorDomain code:err userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Can't find script code for encoding %@", [ImpTextEncodingConverter nameOfTextEncoding:self.textEncodingConverter.hfsTextEncoding]] }];
		self.accessError = noScriptCodeError;
		if (outError != NULL) {
			*outError = noScriptCodeError;
		}
		return false;
	}
	S(extInfo.frScript, (u_int8_t)((script & 0x7f) | 0x80));
	memcpy(&folderRecPtr->finderInfo, &extInfo, sizeof(folderRecPtr->finderInfo));

	memset(folderRecPtr->reserved, 0, sizeof(folderRecPtr->reserved));

	return true;
}
- (void) fillOutHFSCatalogKey:(NSMutableData *_Nonnull const)keyData
	hfsCatalogFolderThread:(NSMutableData *_Nonnull const)payloadData
{
	[self fillOutHFSCatalogThreadKey:keyData ownID:self.assignedItemID];

	struct HFSCatalogThread *_Nonnull const threadRecPtr = payloadData.mutableBytes;
	S(threadRecPtr->recordType, kHFSFolderThreadRecord);
	ImpHydratedFolder *_Nullable const parentFolder = self.parentFolder;
	HFSCatalogNodeID const parentID = parentFolder != nil ? parentFolder.assignedItemID : kHFSRootParentID;
	S(threadRecPtr->parentID, parentID);
	[self convertName:self.name toHFSItemName:threadRecPtr->nodeName];
	memset(threadRecPtr->reserved, 0, sizeof(threadRecPtr->reserved));
}

- (bool) fillOutHFSPlusCatalogKey:(NSMutableData *_Nonnull const)keyData
	hfsPlusCatalogFolder:(NSMutableData *_Nonnull const)payloadData
	error:(out NSError *_Nullable *_Nullable const)outError
{
	ImpHydratedFolder *_Nullable const parentFolder = self.parentFolder;
	HFSCatalogNodeID const parentID = parentFolder != nil ? parentFolder.assignedItemID : kHFSRootParentID;
	[self fillOutHFSPlusCatalogKey:keyData
		parentID:parentID
		nodeName:self.name];

	struct HFSPlusCatalogFolder *_Nonnull const folderRecPtr = payloadData.mutableBytes;
	S(folderRecPtr->recordType, kHFSPlusFolderRecord);

	struct stat dirSB = { 0 };
	struct DXInfo extInfo = { 0 };

	if (self.realWorldURL == nil) {
		//This is an original item—probably the root directory. Populate the stat block as best we can.
		dirSB.st_flags = 0;
		struct timespec now;
		clock_gettime(CLOCK_REALTIME, &now);
		memcpy(&dirSB.st_ctimespec, &now, sizeof(dirSB.st_ctimespec));
		memcpy(&dirSB.st_mtimespec, &now, sizeof(dirSB.st_mtimespec));
		memcpy(&dirSB.st_atimespec, &now, sizeof(dirSB.st_atimespec));
	} else {
		NSFileHandle *_Nonnull const readFH = [self openReadingFileHandle];
		int const fd = readFH.fileDescriptor;
		if (fd < 0) {
			int const dirStatErrno = errno;
			NSError *_Nonnull const dirStatError = [NSError errorWithDomain:NSPOSIXErrorDomain code:dirStatErrno userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Couldn't open folder to catalog it: %@", self.realWorldURL.path] }];
			self.accessError = dirStatError;
			if (outError != NULL) {
				*outError = dirStatError;
			}
			return false;
		}

		int const dirStatResult = fstat(fd, &dirSB);
		if (dirStatResult < 0) {
			int const dirStatErrno = errno;
			NSError *_Nonnull const dirStatError = [NSError errorWithDomain:NSPOSIXErrorDomain code:dirStatErrno userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failure getting vital statistics for folder %@", self.realWorldURL.path] }];
			self.accessError = dirStatError;
			if (outError != NULL) {
				*outError = dirStatError;
			}
			return false;
		}

		NSMutableData *_Nonnull const finderInfoData = [NSMutableData dataWithLength:sizeof(folderRecPtr->userInfo) + sizeof(folderRecPtr->finderInfo)];
		ssize_t const finderInfoLength = fgetxattr(fd, "com.apple.FinderInfo", finderInfoData.mutableBytes, finderInfoData.length, /*position*/ 0, /*options*/ 0);
		if (finderInfoLength < 0) {
			int const getxattrErrno = errno;
			NSError *_Nonnull const getxattrError = [NSError errorWithDomain:NSPOSIXErrorDomain code:getxattrErrno userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failure getting Finder info for item %@", self.realWorldURL.path] }];
			self.accessError = getxattrError;
			if (outError != NULL) {
				*outError = getxattrError;
			}
			return false;
	 	}
		[finderInfoData getBytes:&(folderRecPtr->userInfo) range:(NSRange){ 0, sizeof(folderRecPtr->userInfo) }];
		[finderInfoData getBytes:&extInfo range:(NSRange){ sizeof(folderRecPtr->userInfo), sizeof(extInfo) }];
	}

	/*TN1150 says no flags are defined for folders, so this field is reserved and we have to set it to zero.
	 *TODO: Where does the locked bit get stored for folders, then?
	UInt8 const lockedMask = ((dirSB.st_flags & UF_IMMUTABLE) ? kHFSFileLockedMask : 0);
	//We always create a thread record, so always set this to true.
	UInt8 const hasThreadMask = kHFSThreadExistsMask;
	S(folderRecPtr->flags, lockedMask | hasThreadMask);
	 */
	S(folderRecPtr->flags, 0);
	NSUInteger const numChildren = self.contents.count;
	if (numChildren > UINT32_MAX) {
		//TODO: Is this the right error code? Not that it matters, but what does File Manager return when trying to create a 32,768th file inside a folder on HFS? (Or 65,536th given the type, but https://web.archive.org/web/20020803105007/http://docs.info.apple.com/article.html?artnum=8647 says the limit is 32,767.)
		NSError *_Nonnull const tooManyChildrenError = [NSError errorWithDomain:NSOSStatusErrorDomain code:dirFulErr userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Folder %@ has more items (%lu) than an HFS folder can hold", self.realWorldURL.path, numChildren] }];
		self.accessError = tooManyChildrenError;
		if (outError != NULL) {
			*outError = tooManyChildrenError;
		}
		return false;
	}
	S(folderRecPtr->valence, (u_int32_t)numChildren);

	S(folderRecPtr->folderID, self.assignedItemID);
	S(folderRecPtr->createDate, [self hfsDateForTimespec:&dirSB.st_ctimespec]);
	S(folderRecPtr->contentModDate, [self hfsDateForTimespec:&dirSB.st_mtimespec]);
	S(folderRecPtr->attributeModDate, [self hfsDateForTimespec:&dirSB.st_mtimespec]);
	S(folderRecPtr->accessDate, [self hfsDateForTimespec:&dirSB.st_atimespec]);
	S(folderRecPtr->backupDate, 0);

	memset(&folderRecPtr->bsdInfo, 0, sizeof(folderRecPtr->bsdInfo));

	ScriptCode script;
	OSStatus err = RevertTextEncodingToScriptInfo(self.textEncodingConverter.hfsTextEncoding, &script, /*outLanguageID*/ NULL, /*outFontName*/ NULL);
	if (err != noErr) {
		NSError *_Nonnull const noScriptCodeError = [NSError errorWithDomain:NSOSStatusErrorDomain code:err userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Can't find script code for encoding %@", [ImpTextEncodingConverter nameOfTextEncoding:self.textEncodingConverter.hfsTextEncoding]] }];
		self.accessError = noScriptCodeError;
		if (outError != NULL) {
			*outError = noScriptCodeError;
		}
		return false;
	}
	S(extInfo.frScript, (u_int8_t)((script & 0x7f) | 0x80));
	memcpy(&folderRecPtr->finderInfo, &extInfo, sizeof(folderRecPtr->finderInfo));

	S(folderRecPtr->textEncoding, self.textEncodingConverter.hfsTextEncoding);
	//hfs_format.h documents the flag bit that indicates whether this is populated as being an HFSX-only feature. So for HFS+, we don't set that flag and this is always zero. (Otherwise we would set it to the number of folders, not files, in self.contents.)
	S(folderRecPtr->folderCount, 0);

	return true;
}
- (void) fillOutHFSPlusCatalogKey:(NSMutableData *_Nonnull const)keyData
	hfsPlusCatalogFolderThread:(NSMutableData *_Nonnull const)payloadData
{
	[self fillOutHFSPlusCatalogThreadKey:keyData ownID:self.assignedItemID];

	struct HFSPlusCatalogThread *_Nonnull const threadRecPtr = payloadData.mutableBytes;
	S(threadRecPtr->recordType, kHFSPlusFolderThreadRecord);
	ImpHydratedFolder *_Nullable const parentFolder = self.parentFolder;
	HFSCatalogNodeID const parentID = parentFolder != nil ? parentFolder.assignedItemID : kHFSRootParentID;
	S(threadRecPtr->parentID, parentID);
	[self.textEncodingConverter convertString:self.name toHFSUniStr255:&threadRecPtr->nodeName];
	S(threadRecPtr->reserved, 0);
}

#pragma mark Populating arrays

- (void) recursivelyAddItemsToArray:(NSMutableArray <ImpHydratedItem *> *_Nonnull const)array {
	[array addObject:self];
	for (ImpHydratedItem *_Nonnull const child in self.contents) {
		[child recursivelyAddItemsToArray:array];
	}
}

#pragma mark Contents

- (NSArray <ImpHydratedItem *> *_Nullable) gatherChildrenOrReturnError:(out NSError *_Nullable *_Nullable const)outError {
	if (self.realWorldURL == nil) {
		//An original folder successfully has no real-world children.
		return @[];
	}

	NSArray <NSURL *> *_Nullable const childURLs = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:self.realWorldURL
		includingPropertiesForKeys:@[ NSURLNameKey, NSURLContentModificationDateKey, NSURLCreationDateKey, NSURLContentAccessDateKey, ]
		options:NSDirectoryEnumerationProducesRelativePathURLs
		error:outError];
	if (childURLs == nil) {
		return nil;
	}

	NSMutableArray <ImpHydratedItem *> *_Nonnull const children = [NSMutableArray arrayWithCapacity:childURLs.count];
	for (NSURL *_Nonnull const childURL in childURLs) {
		ImpHydratedItem *_Nullable const childItem = [ImpHydratedItem itemWithRealWorldURL:childURL error:outError];
		childItem.parentFolder = self;
		if (childItem == nil) {
			return nil;
		}
		[children addObject:childItem];
	}

	return children;
}

@end

@implementation ImpHydratedFile
{
	FSRef _ref;
	HFSExtentRecord _hfsDataForkExtents, _hfsRsrcForkExtents;
	HFSPlusExtentRecord _hfsPlusDataForkExtents, _hfsPlusRsrcForkExtents;
}

- (instancetype _Nullable)initWithRealWorldURL:(NSURL *_Nonnull const)fileURL {
	if ((self = [super initWithRealWorldURL:fileURL])) {
		if (! CFURLGetFSRef((__bridge CFURLRef)self.realWorldURL, &_ref)) {
			self = nil;
		}

		_numberOfBytesPerBlock = kISOStandardBlockSize;
		_numberOfBlocksPerDataClump = 4;
		_numberOfBlocksPerResourceClump = 1;
	}
	return self;
}

- (NSString *_Nonnull const) emojiIcon {
	static NSString *_Nonnull const fileEmojiIcon = @"📄";
	return fileEmojiIcon;
}

#pragma mark Real-world access

- (int) permissionsForOpening {
	return O_RDONLY;
}

#pragma mark File properties

///Get the extents that have been allocated for this file's data fork. Will be an empty extent record if not previously set with setDataForkHFSExtentRecord:.
- (void) getDataForkHFSExtentRecord:(struct HFSExtentDescriptor *_Nonnull const)outExtents {
	memcpy(outExtents, _hfsDataForkExtents, sizeof(_hfsDataForkExtents));
}
///Set the extents that have been allocated for this file's data fork.
- (void) setDataForkHFSExtentRecord:(struct HFSExtentDescriptor const *_Nonnull const)inExtents {
	memcpy(_hfsDataForkExtents, inExtents, sizeof(_hfsDataForkExtents));
}

///Get the extents that have been allocated for this file's resource fork. Will be an empty extent record if not previously set with setResourceForkHFSExtentRecord:.
- (void) getResourceForkHFSExtentRecord:(struct HFSExtentDescriptor *_Nonnull const)outExtents {
	memcpy(outExtents, _hfsRsrcForkExtents, sizeof(_hfsRsrcForkExtents));
}
///Set the extents that have been allocated for this file's resource fork.
- (void) setResourceForkHFSExtentRecord:(struct HFSExtentDescriptor const *_Nonnull const)inExtents {
	memcpy(_hfsRsrcForkExtents, inExtents, sizeof(_hfsRsrcForkExtents));
}

///Get the extents that have been allocated for this file's data fork. Will be an empty extent record if not previously set with setDataForkHFSPlusExtentRecord:.
- (void) getDataForkHFSPlusExtentRecord:(struct HFSPlusExtentDescriptor *_Nonnull const)outExtents {
	memcpy(outExtents, _hfsPlusDataForkExtents, sizeof(_hfsPlusDataForkExtents));
}
///Set the extents that have been allocated for this file's data fork.
- (void) setDataForkHFSPlusExtentRecord:(struct HFSPlusExtentDescriptor const *_Nonnull const)inExtents {
	memcpy(_hfsPlusDataForkExtents, inExtents, sizeof(_hfsPlusDataForkExtents));
}

///Get the extents that have been allocated for this file's resource fork. Will be an empty extent record if not previously set with setResourceForkHFSPlusExtentRecord:.
- (void) getResourceForkHFSPlusExtentRecord:(struct HFSPlusExtentDescriptor *_Nonnull const)outExtents {
	memcpy(outExtents, _hfsPlusRsrcForkExtents, sizeof(_hfsPlusRsrcForkExtents));
}
///Set the extents that have been allocated for this file's resource fork.
- (void) setResourceForkHFSPlusExtentRecord:(struct HFSPlusExtentDescriptor const *_Nonnull const)inExtents {
	memcpy(_hfsPlusRsrcForkExtents, inExtents, sizeof(_hfsPlusRsrcForkExtents));
}

#pragma mark Filling out catalog records

- (bool) fillOutHFSCatalogKey:(NSMutableData *_Nonnull const)keyData
	hfsCatalogFile:(NSMutableData *_Nonnull const)payloadData
	error:(out NSError *_Nullable *_Nullable const)outError
{
	ImpHydratedFolder *_Nullable const parentFolder = self.parentFolder;
	HFSCatalogNodeID const parentID = parentFolder != nil ? parentFolder.assignedItemID : kHFSRootParentID;
	[self fillOutHFSCatalogKey:keyData
		parentID:parentID
		nodeName:self.name];

	NSFileHandle *_Nonnull const readFH = [self openReadingFileHandle];
	int const fd = readFH.fileDescriptor;
	if (fd < 0) {
		int const dataStatErrno = errno;
		NSError *_Nonnull const dataStatError = [NSError errorWithDomain:NSPOSIXErrorDomain code:dataStatErrno userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Couldn't open file to catalog it: %@", self.realWorldURL.path] }];
		self.accessError = dataStatError;
		if (outError != NULL) {
			*outError = dataStatError;
		}
		return false;
	}

	struct stat dataSB, rsrcSB;

	int const dataStatResult = fstat(fd, &dataSB);
	if (dataStatResult < 0) {
		int const dataStatErrno = errno;
		NSError *_Nonnull const dataStatError = [NSError errorWithDomain:NSPOSIXErrorDomain code:dataStatErrno userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failure getting vital statistics for data fork of item %@", self.realWorldURL.path] }];
		self.accessError = dataStatError;
		if (outError != NULL) {
			*outError = dataStatError;
		}
		return false;
	} else if (dataSB.st_size > INT32_MAX) {
		NSError *_Nonnull const forkTooBigError = [NSError errorWithDomain:NSOSStatusErrorDomain code:fsDataTooBigErr userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Data fork is too big in file %@", self.realWorldURL.path] }];
		self.accessError = forkTooBigError;
		if (outError != NULL) {
			*outError = forkTooBigError;
		}
		return false;
	}

	int const rsrcStatResult = fstat(fd, &rsrcSB);
	if (rsrcStatResult < 0) {
		int const rsrcStatErrno = errno;
		NSError *_Nonnull const rsrcStatError = [NSError errorWithDomain:NSPOSIXErrorDomain code:rsrcStatErrno userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failure getting vital statistics for resource fork of item %@", self.realWorldURL.path] }];
		self.accessError = rsrcStatError;
		if (outError != NULL) {
			*outError = rsrcStatError;
		}
		return false;
	} else if (rsrcSB.st_size > INT32_MAX) {
		NSError *_Nonnull const forkTooBigError = [NSError errorWithDomain:NSOSStatusErrorDomain code:fsDataTooBigErr userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Resource fork is too big in file %@", self.realWorldURL.path] }];
		self.accessError = forkTooBigError;
		if (outError != NULL) {
			*outError = forkTooBigError;
		}
		return false;
	}

	struct HFSCatalogFile *_Nonnull const fileRecPtr = payloadData.mutableBytes;
	S(fileRecPtr->recordType, kHFSFileRecord);

	UInt8 const lockedMask = ((dataSB.st_flags & UF_IMMUTABLE) ? kHFSFileLockedMask : 0);
	//We always create a thread record, so always set this to true.
	UInt8 const hasThreadMask = kHFSThreadExistsMask;
	S(fileRecPtr->flags, lockedMask | hasThreadMask);
	S(fileRecPtr->fileType, 0);

	NSMutableData *_Nonnull const finderInfoData = [NSMutableData dataWithLength:sizeof(fileRecPtr->userInfo) + sizeof(fileRecPtr->finderInfo)];
	ssize_t const finderInfoLength = fgetxattr(fd, "com.apple.FinderInfo", finderInfoData.mutableBytes, finderInfoData.length, /*position*/ 0, /*options*/ 0);
	if (finderInfoLength < 0) {
		int const getxattrErrno = errno;
		NSError *_Nonnull const getxattrError = [NSError errorWithDomain:NSPOSIXErrorDomain code:getxattrErrno userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failure getting Finder info for item %@", self.realWorldURL.path] }];
		self.accessError = getxattrError;
		if (outError != NULL) {
			*outError = getxattrError;
		}
		return false;
	}
	[finderInfoData getBytes:&(fileRecPtr->userInfo) range:(NSRange){ 0, sizeof(fileRecPtr->userInfo) }];
	struct FXInfo extInfo = { 0 };
	[finderInfoData getBytes:&extInfo range:(NSRange){ sizeof(fileRecPtr->userInfo), sizeof(extInfo) }];

	S(fileRecPtr->fileID, self.assignedItemID);
	S(fileRecPtr->dataStartBlock, 0);
	S(fileRecPtr->dataLogicalSize, (int32_t)dataSB.st_size);
	S(fileRecPtr->dataPhysicalSize, 0);
	S(fileRecPtr->rsrcStartBlock, 0);
	S(fileRecPtr->rsrcLogicalSize, (int32_t)rsrcSB.st_size);
	S(fileRecPtr->rsrcPhysicalSize, 0);
	S(fileRecPtr->createDate, [self hfsDateForTimespec:&dataSB.st_ctimespec]);
	S(fileRecPtr->modifyDate, [self hfsDateForTimespec:&dataSB.st_mtimespec]);
	S(fileRecPtr->backupDate, 0);

	ScriptCode script;
	OSStatus err = RevertTextEncodingToScriptInfo(self.textEncodingConverter.hfsTextEncoding, &script, /*outLanguageID*/ NULL, /*outFontName*/ NULL);
	if (err != noErr) {
		NSError *_Nonnull const noScriptCodeError = [NSError errorWithDomain:NSOSStatusErrorDomain code:err userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Can't find script code for encoding %@", [ImpTextEncodingConverter nameOfTextEncoding:self.textEncodingConverter.hfsTextEncoding]] }];
		self.accessError = noScriptCodeError;
		if (outError != NULL) {
			*outError = noScriptCodeError;
		}
		return false;
	}
	S(extInfo.fdScript, (u_int8_t)((script & 0x7f) | 0x80));
	//TODO: If the resource fork contains a routing resource, we should set kExtendedFlagHasRoutingInfo in extInfo.fdXFlags.
	memcpy(&fileRecPtr->finderInfo, &extInfo, sizeof(fileRecPtr->finderInfo));
	S(fileRecPtr->clumpSize, 0x1000);
	memset(fileRecPtr->dataExtents, 0, sizeof(fileRecPtr->dataExtents));
	memset(fileRecPtr->rsrcExtents, 0, sizeof(fileRecPtr->rsrcExtents));
	S(fileRecPtr->reserved, 0);

	return true;
}
- (void) fillOutHFSCatalogKey:(NSMutableData *_Nonnull const)keyData
	hfsCatalogFileThread:(NSMutableData *_Nonnull const)payloadData
{
	[self fillOutHFSCatalogThreadKey:keyData ownID:self.assignedItemID];

	struct HFSCatalogThread *_Nonnull const threadRecPtr = payloadData.mutableBytes;
	S(threadRecPtr->recordType, kHFSFileThreadRecord);
	ImpHydratedFolder *_Nullable const parentFolder = self.parentFolder;
	HFSCatalogNodeID const parentID = parentFolder != nil ? parentFolder.assignedItemID : kHFSRootParentID;
	S(threadRecPtr->parentID, parentID);
	[self convertName:self.name toHFSItemName:threadRecPtr->nodeName];
	memset(threadRecPtr->reserved, 0, sizeof(threadRecPtr->reserved));
}

- (u_int32_t) hfsTimestampFromUTCDateTime:(struct UTCDateTime const *_Nonnull const)utcDateTime {
	return utcDateTime->lowSeconds;
}

- (bool) fillOutHFSPlusCatalogKey:(NSMutableData *_Nonnull const)keyData
	hfsPlusCatalogFile:(NSMutableData *_Nonnull const)payloadData
	error:(out NSError *_Nullable *_Nullable const)outError
{
	ImpHydratedFolder *_Nullable const parentFolder = self.parentFolder;
	HFSCatalogNodeID const parentID = parentFolder != nil ? parentFolder.assignedItemID : kHFSRootParentID;
	[self fillOutHFSPlusCatalogKey:keyData
		parentID:parentID
		nodeName:self.name];

	struct FSCatalogInfo catInfo = { 0 };
	OSStatus err = FSGetCatalogInfo(&_ref, kFSCatInfoAllDates | kFSCatInfoNodeFlags | kFSCatInfoFinderInfo | kFSCatInfoFinderXInfo | kFSCatInfoTextEncoding | kFSCatInfoDataSizes | kFSCatInfoRsrcSizes | kFSCatInfoPermissions, &catInfo, /*outUnicodeName*/ NULL, /*outFSSpec*/ NULL, /*outParentRef*/ NULL);

	u_int32_t const blockSize = self.numberOfBytesPerBlock;

	struct HFSPlusCatalogFile *_Nonnull const fileRecPtr = payloadData.mutableBytes;
	S(fileRecPtr->recordType, kHFSPlusFileRecord);

	UInt8 const lockedMask = (
		catInfo.nodeFlags & kFSNodeLockedMask
		? kHFSFileLockedMask
		: 0
	);
	//We always create a thread record, so always set this to true.
	UInt8 const hasThreadMask = kHFSThreadExistsMask;
	S(fileRecPtr->flags, lockedMask | hasThreadMask);
	S(fileRecPtr->reserved1, 0);

	S(fileRecPtr->fileID, self.assignedItemID);
	S(fileRecPtr->createDate, [self hfsTimestampFromUTCDateTime:&catInfo.createDate]);
	S(fileRecPtr->contentModDate, [self hfsTimestampFromUTCDateTime:&catInfo.contentModDate]);
	S(fileRecPtr->attributeModDate, [self hfsTimestampFromUTCDateTime:&catInfo.attributeModDate]);
	S(fileRecPtr->accessDate, [self hfsTimestampFromUTCDateTime:&catInfo.accessDate]);
	S(fileRecPtr->backupDate, [self hfsTimestampFromUTCDateTime:&catInfo.backupDate]);

	S(fileRecPtr->bsdInfo.ownerID, catInfo.permissions.userID);
	S(fileRecPtr->bsdInfo.groupID, catInfo.permissions.groupID);
	S(fileRecPtr->bsdInfo.fileMode, catInfo.permissions.mode);
	S(fileRecPtr->bsdInfo.ownerFlags, 0);
	S(fileRecPtr->bsdInfo.adminFlags, 0);
	S(fileRecPtr->bsdInfo.special.linkCount, 0);

	memcpy(&(fileRecPtr->userInfo), &(catInfo.finderInfo), sizeof(fileRecPtr->userInfo));
	struct FXInfo extInfo = { 0 };
	memcpy(&extInfo, &(catInfo.extFinderInfo), sizeof(extInfo));
	ScriptCode script;
	err = RevertTextEncodingToScriptInfo(self.textEncodingConverter.hfsTextEncoding, &script, /*outLanguageID*/ NULL, /*outFontName*/ NULL);
	if (err != noErr) {
		NSError *_Nonnull const noScriptCodeError = [NSError errorWithDomain:NSOSStatusErrorDomain code:err userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Can't find script code for encoding %@", [ImpTextEncodingConverter nameOfTextEncoding:self.textEncodingConverter.hfsTextEncoding]] }];
		self.accessError = noScriptCodeError;
		if (outError != NULL) {
			*outError = noScriptCodeError;
		}
		return false;
	}
	S(extInfo.fdScript, (u_int8_t)((script & 0x7f) | 0x80));
	//TODO: If the resource fork contains a routing resource, we should set kExtendedFlagHasRoutingInfo in extInfo.fdXFlags.
	memcpy(&fileRecPtr->finderInfo, &extInfo, sizeof(fileRecPtr->finderInfo));

	S(fileRecPtr->dataFork.logicalSize, catInfo.dataLogicalSize);
	memset(fileRecPtr->dataFork.extents, 0, sizeof(fileRecPtr->dataFork.extents));
	S(fileRecPtr->dataFork.totalBlocks, 0);
	S(fileRecPtr->dataFork.clumpSize, blockSize * self.numberOfBlocksPerDataClump);
	S(fileRecPtr->resourceFork.logicalSize, catInfo.rsrcLogicalSize);
	memset(fileRecPtr->resourceFork.extents, 0, sizeof(fileRecPtr->resourceFork.extents));
	S(fileRecPtr->resourceFork.totalBlocks, 0);
	S(fileRecPtr->resourceFork.clumpSize, blockSize * self.numberOfBlocksPerResourceClump);

	S(fileRecPtr->textEncoding, catInfo.textEncodingHint);
	S(fileRecPtr->reserved2, 0);

	return true;
}
- (void) fillOutHFSPlusCatalogKey:(NSMutableData *_Nonnull const)keyData
	hfsPlusCatalogFileThread:(NSMutableData *_Nonnull const)payloadData
{
	[self fillOutHFSPlusCatalogThreadKey:keyData ownID:self.assignedItemID];

	struct HFSPlusCatalogThread *_Nonnull const threadRecPtr = payloadData.mutableBytes;
	S(threadRecPtr->recordType, kHFSPlusFileThreadRecord);
	ImpHydratedFolder *_Nullable const parentFolder = self.parentFolder;
	HFSCatalogNodeID const parentID = parentFolder != nil ? parentFolder.assignedItemID : kHFSRootParentID;
	S(threadRecPtr->parentID, parentID);
	[self.textEncodingConverter convertString:self.name toHFSUniStr255:&threadRecPtr->nodeName];
	S(threadRecPtr->reserved, 0);
}

#pragma mark Populating arrays

- (void) recursivelyAddItemsToArray:(NSMutableArray <ImpHydratedItem *> *_Nonnull const)array {
	[array addObject:self];
}

#pragma mark Contents

- (bool) getLength:(out u_int64_t *_Nonnull const)outLength
	fromFileHandle:(NSFileHandle *_Nonnull const)fh
	path:(NSString *_Nonnull const)path
	forkName:(NSString *_Nonnull const)forkName
	error:(out NSError *_Nullable *_Nullable const)outError
{
	int const fd = fh.fileDescriptor;
	off_t const whereWeLeftOff = lseek(fd, 0, SEEK_CUR);
	off_t const theEnd = lseek(fd, 0, SEEK_END);
	if (theEnd >= 0) {
		*outLength = theEnd;
	} else {
		int const seekErrno = errno;
		NSError *_Nonnull const seekError = [NSError errorWithDomain:NSPOSIXErrorDomain code:seekErrno userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to get %@ fork length for %@: %s", forkName, path, strerror(seekErrno)] }];
		if (outError != NULL) {
			*outError = seekError;
		}
		return false;
	}
	if (whereWeLeftOff >= 0) {
		lseek(fd, whereWeLeftOff, SEEK_SET);
	}
	if ([path.lastPathComponent isEqualToString:@"Desktop"] || [path.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent.lastPathComponent isEqualToString:@"Desktop"]) {
		ImpPrintf(@"Weighing the %@ fork of the Desktop: %llu", forkName, theEnd);
	}
	return true;
}
- (bool) getDataForkLength:(out u_int64_t *_Nonnull const)outLength error:(out NSError *_Nullable *_Nullable const)outError {
	struct FSCatalogInfo catInfo = { 0 };
	OSStatus const err = FSGetCatalogInfo(&_ref, kFSCatInfoDataSizes, &catInfo, /*outUnicodeName*/ NULL, /*outFSSpec*/ NULL, /*outParentRef*/ NULL);
	bool const success = (err == noErr);
	if (success) {
		*outLength = catInfo.dataLogicalSize;
	} else {
		NSError *_Nonnull const getCatInfoError = [NSError errorWithDomain:NSOSStatusErrorDomain code:err userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Couldn't get data fork logical length for %@: %d/%s", self.realWorldURL.path, err, GetMacOSStatusCommentString(err)] }];
		if (outError != NULL) {
			*outError = getCatInfoError;
		}
	}
	return success;
}
- (bool) getResourceForkLength:(out u_int64_t *_Nonnull const)outLength error:(out NSError *_Nullable *_Nullable const)outError {
	struct FSCatalogInfo catInfo = { 0 };
	OSStatus const err = FSGetCatalogInfo(&_ref, kFSCatInfoRsrcSizes, &catInfo, /*outUnicodeName*/ NULL, /*outFSSpec*/ NULL, /*outParentRef*/ NULL);
	bool const success = (err == noErr);
	if (success) {
		*outLength = catInfo.rsrcLogicalSize;
	} else {
		NSError *_Nonnull const getCatInfoError = [NSError errorWithDomain:NSOSStatusErrorDomain code:err userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Couldn't get resource fork logical length for %@: %d/%s", self.realWorldURL.path, err, GetMacOSStatusCommentString(err)] }];
		if (outError != NULL) {
			*outError = getCatInfoError;
		}
	}
	return success;
}

- (bool) readFromForkNamed:(ConstHFSUniStr255Param _Nonnull const)forkName
	block:(bool (^_Nonnull const)(NSData *_Nonnull const data))block
	openFailuresAreFatal:(bool const)openFailuresAreFatal
	error:(out NSError *_Nullable *_Nullable const)outError
{
	FSIORefNum fileRefNum = -1;
	OSStatus err = FSOpenFork(&_ref, forkName->length, forkName->unicode, fsRdPerm, &fileRefNum);
	if (err == eofErr) {
		//No/empty resource fork. This is an immediate success condition.
		return true;
	}
	if (err != noErr) {
		NSError *_Nonnull const openFailError = [NSError errorWithDomain:NSOSStatusErrorDomain code:err userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to open %@ fork of %@: %d/%s", forkName == &dataForkName ? @"data" : @"resource", self.realWorldURL.path, err, GetMacOSStatusCommentString(err) ] }];
		if (outError != NULL) {
			*outError = openFailError;
		}
		return false;
	}

	enum { chunkSize = 10485760UL };
	NSMutableData *_Nonnull const chunkData = [NSMutableData dataWithLength:chunkSize];
	bool keepGoing = true;
	ByteCount amtRead = 0;
	while ((err = FSReadFork(fileRefNum, fsAtMark, /*offset*/ +0, /*requestCount*/ chunkSize, chunkData.mutableBytes, &amtRead)) == noErr && amtRead > 0) {
		chunkData.length = amtRead;
		keepGoing = block(chunkData);
		chunkData.length = chunkSize;
	}
	FSCloseFork(fileRefNum);
	if (! keepGoing) {
		return false;
	} else if (err == eofErr) {
		//We successfully read everything.
	} else if (err != noErr) {
		NSError *_Nonnull const readFailError = [NSError errorWithDomain:NSOSStatusErrorDomain code:err userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to read from %@ fork of %@: %d/%s", forkName == &dataForkName ? @"data" : @"resource", self.realWorldURL.path, err, GetMacOSStatusCommentString(err) ] }];
		if (outError != NULL) {
			*outError = readFailError;
		}
		return false;
	}

	return true;
}

- (bool) readDataFork:(bool (^_Nonnull const)(NSData *_Nonnull const data))block error:(out NSError *_Nullable *_Nullable const)outError {
	return [self readFromForkNamed:&dataForkName block:block openFailuresAreFatal:true error:outError];
}
- (bool) readResourceFork:(bool (^_Nonnull const)(NSData *_Nonnull const data))block error:(out NSError *_Nullable *_Nullable const)outError {
	return [self readFromForkNamed:&resourceForkName block:block openFailuresAreFatal:false error:outError];
}

@end
