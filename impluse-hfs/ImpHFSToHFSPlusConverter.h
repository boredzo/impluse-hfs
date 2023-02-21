//
//  ImpHFSToHFSPlusConverter.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-26.
//

#import <Foundation/Foundation.h>

///progress is a value from 0.0 to 1.0. 1.0 means the conversion has finished. operationDescription is a string describing what work is currently being done.
typedef void (^ImpConversionProgressUpdateBlock)(double progress, NSString *_Nonnull operationDescription);

@class ImpHFSVolume, ImpHFSPlusVolume;
@class ImpBTreeFile, ImpMutableBTreeFile;

@interface ImpHFSToHFSPlusConverter : NSObject

///Which encoding to interpret HFS volume, folder, and file names as. Defaults to MacRoman.
@property TextEncoding hfsTextEncoding;

///Initialized during step 1 of conversion (the volume header) to the source volume's number of blocks used.
@property(readwrite) NSUInteger numberOfSourceBlocksToCopy;
///The number of blocks from the source volume that have been copied.
@property(readwrite) NSUInteger numberOfSourceBlocksCopied;
///Increase self.numberOfSourceBlocksCopied by this number.
- (void) reportSourceBlocksCopied:(NSUInteger const)thisManyMore;
///Decrease self.numberOfSourceBlocksToCopy by this number.
- (void) reportSourceBlocksWillNotBeCopied:(NSUInteger const)thisManyFewer;
///Increase self.numberOfSourceBlocksCopied by the total number of blocks indicated by an extent record.
- (void) reportSourceExtentRecordCopied:(struct HFSExtentDescriptor const *_Nonnull const)extRecPtr;
///Decrease self.numberOfSourceBlocksToCopy by the total number of blocks indicated by an extent record.
- (void) reportSourceExtentRecordWillNotBeCopied:(struct HFSExtentDescriptor const *_Nonnull const)extRecPtr;

///This block is called for every progress update.
@property(copy) ImpConversionProgressUpdateBlock _Nullable conversionProgressUpdateBlock;

///Read an HFS volume from this device. (Does not actually need to be a device but will be assumed to be one.)
@property(copy) NSURL *_Nullable sourceDevice;
///Write an HFS volume to this device. (Does not actually need to be a device but will be assumed to be one.)
@property(copy) NSURL *_Nullable destinationDevice;

- (bool)performConversionOrReturnError:(NSError *_Nullable *_Nonnull) outError;

#pragma mark Methods for subclasses' use

///Calls self.conversionProgressUpdateBlock with these values.
- (void) deliverProgressUpdate:(double)progress
	operationDescription:(NSString *_Nonnull)operationDescription;
///Calls self.conversionProgressUpdateBlock with a progress factor derived from the number of source blocks copied relative to the number to copy.
- (void) deliverProgressUpdateWithOperationDescription:(NSString *_Nonnull)operationDescription;

///Set by concrete subclasses as part of the conversion.
@property(strong) ImpHFSVolume *_Nonnull sourceVolume;
///Set by concrete subclasses as part of the conversion.
@property(strong) ImpHFSPlusVolume *_Nonnull destinationVolume;

- (NSData *_Nonnull const)hfsUniStr255ForPascalString:(ConstStr31Param _Nonnull)pascalString;
- (NSString *_Nonnull const) stringForPascalString:(ConstStr31Param _Nonnull)pascalString;

///Returns the total length of the converted key, including the length field.
- (NSUInteger) convertHFSCatalogKey:(struct HFSCatalogKey const *_Nonnull const)srcKeyPtr toHFSPlus:(struct HFSPlusCatalogKey *_Nonnull const)dstKeyPtr;
- (NSMutableData *_Nonnull) convertHFSCatalogKeyToHFSPlus:(NSData *_Nonnull const)sourceKeyData;

- (void) convertHFSVolumeHeader:(struct HFSMasterDirectoryBlock const *_Nonnull const)mdbPtr toHFSPlusVolumeHeader:(struct HFSPlusVolumeHeader *_Nonnull const)vhPtr;
- (void) copyFromHFSCatalogFile:(ImpBTreeFile *_Nonnull const)sourceTree toHFSPlusCatalogFile:(ImpMutableBTreeFile *_Nonnull const)destTree;

///Open files for reading and writing and do any other preflight checks before conversion begins. The abstract class implements this method. After this method returns, self.hfsVolume and self.hfsPlusVolume are non-nil.
- (bool) step0_preflight_error:(NSError *_Nullable *_Nullable const)outError;
///Convert the boot blocks and volume header. The abstract class implements this method.
- (bool) step1_convertPreamble_error:(NSError *_Nullable *_Nullable const)outError;
///Convert the volume bitmap, catalog file, and extents overflow file, and copy over user data. This is expected to be the bulk of the work, and is intentionally broad because it's where the most subclass variation will be. The abstract class DOES NOT IMPLEMENT this method; a subclass must override it.
- (bool) step2_convertVolume_error:(NSError *_Nullable *_Nullable const)outError;
///Finalize the conversion and write the preamble and postamble to disk. If this step succeeds, the converted volume should be mountable. The abstract class implements this method.
- (bool) step3_flushVolume_error:(NSError *_Nullable *_Nullable const)outError;

@end
