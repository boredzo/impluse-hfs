//
//  ImpDehydratedItem.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-02.
//

#import <Foundation/Foundation.h>

@class ImpHFSVolume;

typedef NS_ENUM(NSUInteger, ImpDehydratedItemType) {
	ImpDehydratedItemTypeFile,
	ImpDehydratedItemTypeFolder,
};

///A dehydrated item is a file or folder that exists within a source volume.
@interface ImpDehydratedItem : NSObject

///Create a dehydrated item object that references a given HFS catalog. The initializer will populate the object's properties with the catalog's data for the given catalog node ID.
- (instancetype _Nonnull) initWithHFSVolume:(ImpHFSVolume *_Nonnull const)hfsVol
	catalogNodeID:(HFSCatalogNodeID const)cnid
	key:(struct HFSCatalogKey const *_Nonnull const)key
	fileRecord:(struct HFSCatalogFile const *_Nonnull const)fileRec;

///Create a dehydrated item object that references a given HFS catalog. The initializer will populate the object's properties with the catalog's data for the given catalog node ID.
- (instancetype _Nonnull) initWithHFSVolume:(ImpHFSVolume *_Nonnull const)hfsVol	catalogNodeID:(HFSCatalogNodeID const)cnid
	key:(struct HFSCatalogKey const *_Nonnull const)key
	folderRecord:(struct HFSCatalogFolder const *_Nonnull const)folderRec;

@property(weak) ImpHFSVolume * _Nullable hfsVolume;
@property HFSCatalogNodeID catalogNodeID;
@property ImpDehydratedItemType type;
@property(nonatomic, readonly) bool isDirectory;

@property(copy) NSData *_Nonnull hfsCatalogKeyData;
@property(copy) NSData *_Nullable hfsFileCatalogRecordData;
@property(copy) NSData *_Nullable hfsFolderCatalogRecordData;

///Defaults to MacRoman.
@property TextEncoding hfsTextEncoding;

///Convert the item's name from the HFS catalog using its assigned encoding into a modern Unicode name.
- (NSString *_Nonnull const) name;
///Convert the item's name from the HFS catalog using this encoding into a modern Unicode name.
- (NSString *_Nonnull const) nameFromEncoding:(TextEncoding)hfsTextEncoding;
///Reconstruct the path to the item from the volume's catalog. Returns an array of item names, starting with the volume name, that, if joined by colons, will form an HFS path.
- (NSArray <NSString *> *_Nonnull const) path;

///Create a real file or folder with the same contents and (as much as possible) metadata as the dehydrated item. Folders get rehydrated recursively, with all of their sub-items. Note that this must be the URL of the item to be created (i.e., parent directory + nameFromEncoding:).
- (bool) rehydrateAtRealWorldURL:(NSURL *_Nonnull const)realWorldURL error:(NSError *_Nullable *_Nonnull const)outError;

///Create a real file or folder with the same contents and (as much as possible) metadata as the dehydrated item. Folders get rehydrated recursively, with all of their sub-items. The item's filename will be converted to Unicode and appended to realWorldParentURL.
- (bool) rehydrateIntoRealWorldDirectoryAtURL:(NSURL *_Nonnull const)realWorldParentURL error:(NSError *_Nullable *_Nonnull const)outError;

@end
