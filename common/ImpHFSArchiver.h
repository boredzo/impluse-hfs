//
//  ImpHFSArchiver.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2024-03-08.
//

#import <Foundation/Foundation.h>

@class ImpTextEncodingConverter;

///progress is a value from 0.0 to 1.0. 1.0 means the conversion has finished. operationDescription is a string describing what work is currently being done.
typedef void (^ImpArchivingProgressUpdateBlock)(double progress, NSString *_Nonnull operationDescription);

///Parse a size-spec, which might be either a well-known name (like “hd20”) or a number and optional unit (like “800K”). Returns a number of bytes. Note that numbers that aren't multiples of kISOStandardBlockSize may be special; see ImpVolumeSizeSmallestPossibleFloppy for an example.
u_int64_t ImpParseSizeSpecification(NSString *_Nonnull const sizeSpec);

///Magic volume-size values. Normal volume sizes should generally be a multiple of 0x200; sizes that aren't may work incorrectly.
typedef NS_ENUM(u_int64_t, ImpVolumeSize) {
	///Magic volume size value to indicate that it should create a volume of the smallest floppy-disk size that will fit the contents.
	ImpVolumeSizeSmallestPossibleFloppy = 0x1440UL,
};

typedef NSString *ImpArchiveVolumeFormat NS_STRING_ENUM;
extern ImpArchiveVolumeFormat _Nonnull const ImpArchiveVolumeFormatHFSClassic;
extern ImpArchiveVolumeFormat _Nonnull const ImpArchiveVolumeFormatHFSPlus;
///Given a user-provided string, return the volume format (file system) it indicates, or return nil if the string does not match a supported volume format.
ImpArchiveVolumeFormat _Nullable const ImpArchiveVolumeFormatFromString(NSString *_Nonnull const volumeFormatString);

@interface ImpHFSArchiver : NSObject

///First encoder to to try encoding volume, folder, and file names with. When set, inserts this encoder before the default series of encoders to try.
@property(strong) ImpTextEncodingConverter *_Nullable textEncodingConverter;

///This block is called for every progress update.
@property(copy) ImpArchivingProgressUpdateBlock _Nullable archivingProgressUpdateBlock;

///Regular files and folders in the real world to populate the volume's root directory with.
@property(copy) NSArray <NSURL *> *_Nullable sourceItems;
///A folder in the real world to use from which to populate the volume's root directory. If sourceItems is also non-nil, those items will be added alongside the contents of this folder.
@property(copy) NSURL *_Nullable sourceRootFolder;

///The size of the complete volume, from the boot blocks to the alternate volume header. If zero, then the volume will be as big as it needs to be to hold the contents.
@property(assign) u_int64_t volumeSizeInBytes;

///The name of the volume and its root directory. If nil, defaults to sourceRootFolder.lastPathComponent. If *that's* nil, defaults to the lastPathComponent of the only item in sourceItems. If that's non-nil, defaults to something else.
@property(copy) NSString *_Nonnull volumeName;

///The file system to create. Defaults to ImpArchiveVolumeFormatHFSClassic.
@property(copy) ImpArchiveVolumeFormat _Nonnull volumeFormat;

///Write the created HFS volume to this device. (Does not actually need to be a device; indeed, for this purpose, it'll usually be a regular file.)
@property(copy) NSURL *_Nullable destinationDevice;

- (bool)performArchivingOrReturnError:(NSError *_Nullable *_Nonnull) outError;

@end
