//
//  ImpHydratedItem.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2024-03-10.
//

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSUInteger, ImpItemClassification) {
	///An error occurred while trying to stat the item. It may have moved or otherwise not exist.
	ImpItemClassificationNonexistent,
	///Regular files and folders can be dehydrated. Note that whether a folder can be dehydrated is independent of whether any items inside that folder can be dehydrated. For example, /dev can be dehydrated, but the devices inside can't.
	ImpItemClassificationRegularFile = S_IFREG,
	ImpItemClassificationFolder = S_IFDIR,
	///Symbolic links can't be dehydrated themselves. Instead, the archiver would want to dehydrate the original item. If that's easy, then the classifier returns the classification of the original item. Otherwise, it returns this.
	ImpItemClassificationSymbolicLinkDifficult = S_IFLNK,
	///Anything that isn't a file or folder or a symlink to one, such as a pipe or device, cannot be dehydrated.
	ImpItemClassificationIrregularFile = S_IFMT,
};

@class ImpTextEncodingConverter;
@class ImpHydratedFolder;
@class ImpCatalogItem;

///A hydrated item is the opposite a dehydrated item (ImpDehydratedItem). A dehydrated item is an item stored within a source volume, represented to be rehydrated into the real world; a hydrated item is one that exists in the real world, represented to be dehydrated into a destination volume.
@interface ImpHydratedItem : NSObject <NSCopying>
{
	NSUInteger _originalItemNumber;
}

///Determine what the best course of action for an item in the real world is.
+ (ImpItemClassification) classifyRealWorldURL:(NSURL *_Nonnull const)fileURL error:(out NSError *_Nullable *_Nullable const)outError;

///Given a URL to a real-world item, return an object representing it if it can be dehydrated, or nil.
+ (instancetype _Nullable) itemWithRealWorldURL:(NSURL *_Nonnull const)fileURL error:(out NSError *_Nullable *_Nullable const)outError;

///Return a hydrated folder
+ (instancetype _Nonnull) itemWithOriginalFolder;

///The file URL in the real world that this item represents.
@property(copy) NSURL *_Nullable realWorldURL;

///The name of the item. For items in the real world, this defaults to the item's real-world lastPathComponent, though it can be changed to diverge from that. For original items, this must be set to something non-nil.
@property(copy) NSString *_Nonnull name;

///The catalog item ID assigned to this item. Initially 0. Must be set to non-zero before an item can be added to the catalog.
@property(assign) HFSCatalogNodeID assignedItemID;

///The folder that the item resides in. If nil, catalog records will be written with the parent folder ID being the parent of the volume root (i.e., the receiver is the root folder).
@property(weak) ImpHydratedFolder *_Nullable parentFolder;

///Stash the catalog item from a catalog builder here for when the catalog item needs to be updated to pick up changes to the hydrated item's catalog records.
@property(weak) ImpCatalogItem *_Nullable catalogItem;

///If an error occurred while accessing any aspect of the file (from metadata such as its length to fork contents), this property will contain that error.
@property(strong) NSError *_Nullable accessError;

#pragma mark Real-world access

///An existing file handle to use for reading, fstat, etc. openReadingFileHandle will return this file handle if it exists. closeReadingFileHandle will close and destroy it.
@property(weak) NSFileHandle *_Nullable readingFileHandle;

///Permissions for openReadingFileHandle to use. Subclasses must override this (e.g., for opening directories vs. files). The abstract implementation throws an exception.
@property(nonatomic) int permissionsForOpening;

///Open the reading file handle if it isn't already, and return it.
- (NSFileHandle *_Nonnull const) openReadingFileHandle;

///Close the reading file handle if it exists, and destroy it.
- (void) closeReadingFileHandle;

#pragma mark Hierarchy flattening

///Adds the receiver, followed by any sub-items, to the given array. If the receiver is a file, then it will add itself only.
///The method is allowed but not required to use a fully breadth-first order.
- (void) recursivelyAddItemsToArray:(NSMutableArray <ImpHydratedItem *> *_Nonnull const)array;

#pragma mark Name encoding

@property(strong) ImpTextEncodingConverter *_Nonnull textEncodingConverter;

///Check whether the item's name can be encoded as a Str31 with its current text encoding converter. Call this before trying to fill out HFS catalog keys or records.
- (bool) checkItemName:(out NSError *_Nullable *_Nullable const)outError;

///Check whether the item's name can be encoded as a Str27 with its current text encoding converter. Call this before trying to fill out an HFS volume header.
- (bool) checkVolumeName:(out NSError *_Nullable *_Nullable const)outError;

#pragma mark Date utilities

///Convert the moment represented by an NSDate object to an HFS timestamp.
///offsetSeconds represents the time zone offset to apply to the date, since HFS uses “local time” rather than GMT for all dates. This is also important for HFS+, which uses local time for the volume creation date in the volume header (as documented by TN1150).
+ (u_int32_t) hfsDateForDate:(NSDate *_Nonnull const)dateToConvert timeZoneOffset:(long)offsetSeconds;

#pragma mark Subclass conveniences

///Utility for subclasses to fill out a catalog key for a file or folder record.
- (void) fillOutHFSCatalogKey:(NSMutableData *_Nonnull const)keyData
	parentID:(HFSCatalogNodeID)parentID
	nodeName:(NSString *_Nonnull const)nodeName;

///Utility for subclasses to fill out a catalog key for a thread record.
- (void) fillOutHFSCatalogThreadKey:(NSMutableData *_Nonnull const)keyData
	ownID:(HFSCatalogNodeID)ownID;

///Utility for subclasses to fill out a catalog key for a file or folder record.
- (void) fillOutHFSPlusCatalogKey:(NSMutableData *_Nonnull const)keyData
	parentID:(HFSCatalogNodeID)parentID
	nodeName:(NSString *_Nonnull const)nodeName;

///Utility for subclasses to fill out a catalog key for a thread record.
- (void) fillOutHFSPlusCatalogThreadKey:(NSMutableData *_Nonnull const)keyData
	ownID:(HFSCatalogNodeID)ownID;

@end

@interface ImpHydratedFolder : ImpHydratedItem

- (bool) fillOutHFSCatalogKey:(NSMutableData *_Nonnull const)keyData
	hfsCatalogFolder:(NSMutableData *_Nonnull const)payloadData
	error:(out NSError *_Nullable *_Nullable const)outError;
- (void) fillOutHFSCatalogKey:(NSMutableData *_Nonnull const)keyData
	hfsCatalogFolderThread:(NSMutableData *_Nonnull const)payloadData;

- (bool) fillOutHFSPlusCatalogKey:(NSMutableData *_Nonnull const)keyData
	hfsPlusCatalogFolder:(NSMutableData *_Nonnull const)payloadData
	error:(out NSError *_Nullable *_Nullable const)outError;
- (void) fillOutHFSPlusCatalogKey:(NSMutableData *_Nonnull const)keyData
	hfsPlusCatalogFolderThread:(NSMutableData *_Nonnull const)payloadData;

#pragma mark Contents

///Instantiates a ImpHydratedItem for every item inside the folder. Returns nil if the folder no longer exists, isn't accessible, or some other error occurs. This result is not reused; you will need to store it somewhere (e.g., the contents property).
- (NSArray <ImpHydratedItem *> *_Nullable) gatherChildrenOrReturnError:(out NSError *_Nullable *_Nullable const)outError;

@property(copy) NSArray <ImpHydratedItem *> *_Nonnull contents;

@end

@interface ImpHydratedFile : ImpHydratedItem

#pragma mark Destination volume properties

///Should be set to the same value as the destination volume. Used to compute clump sizes.
@property u_int32_t numberOfBytesPerBlock;
///The multiplier for the clump size in data forks. There is little if any reason to change this.
@property u_int32_t numberOfBlocksPerDataClump;
///The multiplier for the clump size in resource forks. There is little if any reason to change this.
@property u_int32_t numberOfBlocksPerResourceClump;

#pragma mark File properties

///Get the extents that have been allocated for this file's data fork. Will be an empty extent record if not previously set with setDataForkHFSExtentRecord:.
- (void) getDataForkHFSExtentRecord:(struct HFSExtentDescriptor *_Nonnull const)outExtents;
///Set the extents that have been allocated for this file's data fork.
- (void) setDataForkHFSExtentRecord:(struct HFSExtentDescriptor const *_Nonnull const)inExtents;

///Get the extents that have been allocated for this file's resource fork. Will be an empty extent record if not previously set with setResourceForkHFSExtentRecord:.
- (void) getResourceForkHFSExtentRecord:(struct HFSExtentDescriptor *_Nonnull const)outExtents;
///Set the extents that have been allocated for this file's resource fork.
- (void) setResourceForkHFSExtentRecord:(struct HFSExtentDescriptor const *_Nonnull const)inExtents;

///Get the extents that have been allocated for this file's data fork. Will be an empty extent record if not previously set with setDataForkHFSPlusExtentRecord:.
- (void) getDataForkHFSPlusExtentRecord:(struct HFSPlusExtentDescriptor *_Nonnull const)outExtents;
///Set the extents that have been allocated for this file's data fork.
- (void) setDataForkHFSPlusExtentRecord:(struct HFSPlusExtentDescriptor const *_Nonnull const)inExtents;

///Get the extents that have been allocated for this file's resource fork. Will be an empty extent record if not previously set with setResourceForkHFSPlusExtentRecord:.
- (void) getResourceForkHFSPlusExtentRecord:(struct HFSPlusExtentDescriptor *_Nonnull const)outExtents;
///Set the extents that have been allocated for this file's resource fork.
- (void) setResourceForkHFSPlusExtentRecord:(struct HFSPlusExtentDescriptor const *_Nonnull const)inExtents;

#pragma mark Filling out catalog records

- (bool) fillOutHFSCatalogKey:(NSMutableData *_Nonnull const)keyData
	hfsCatalogFile:(NSMutableData *_Nonnull const)payloadData
	error:(out NSError *_Nullable *_Nullable const)outError;
- (void) fillOutHFSCatalogKey:(NSMutableData *_Nonnull const)keyData
	hfsCatalogFileThread:(NSMutableData *_Nonnull const)payloadData;

- (bool) fillOutHFSPlusCatalogKey:(NSMutableData *_Nonnull const)keyData
	hfsPlusCatalogFile:(NSMutableData *_Nonnull const)payloadData
	error:(out NSError *_Nullable *_Nullable const)outError;
- (void) fillOutHFSPlusCatalogKey:(NSMutableData *_Nonnull const)keyData
	hfsPlusCatalogFileThread:(NSMutableData *_Nonnull const)payloadData;

#pragma mark Contents

- (bool) getDataForkLength:(out u_int64_t *_Nonnull const)outLength error:(out NSError *_Nullable *_Nullable const)outError;
- (bool) getResourceForkLength:(out u_int64_t *_Nonnull const)outLength error:(out NSError *_Nullable *_Nullable const)outError;

- (bool) readDataFork:(bool (^_Nonnull const)(NSData *_Nonnull const data))block error:(out NSError *_Nullable *_Nullable const)outError;
- (bool) readResourceFork:(bool (^_Nonnull const)(NSData *_Nonnull const data))block error:(out NSError *_Nullable *_Nullable const)outError;

@end
