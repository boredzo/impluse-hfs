//
//  ImpHFSToHFSPlusConverter.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-26.
//

#import <Foundation/Foundation.h>

///progress is a value from 0.0 to 1.0. 1.0 means the conversion has finished. operationDescription is a string describing what work is currently being done.
typedef void (^ImpConversionProgressUpdateBlock)(float progress, NSString *_Nonnull operationDescription);

@interface ImpHFSToHFSPlusConverter : NSObject

///Which encoding to interpret HFS volume, folder, and file names as. Defaults to MacRoman.
@property TextEncoding hfsTextEncoding;

///This block is called for every progress update.
@property(copy) ImpConversionProgressUpdateBlock _Nullable conversionProgressUpdateBlock;

///Read an HFS volume from this device. (Does not actually need to be a device but will be assumed to be one.)
@property(copy) NSURL *_Nullable sourceDevice;
///Write an HFS volume to this device. (Does not actually need to be a device but will be assumed to be one.)
@property(copy) NSURL *_Nullable destinationDevice;

- (bool)performConversionOrReturnError:(NSError *_Nullable *_Nonnull) outError;

@end
