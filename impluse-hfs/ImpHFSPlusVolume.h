//
//  ImpHFSPlusVolume.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-26.
//

#import <Foundation/Foundation.h>

@interface ImpHFSPlusVolume : NSObject

@property(copy) NSData *_Nonnull bootBlocks;
@property(copy) NSData *_Nonnull volumeHeader;

- (void) createAllocationFileFromHFSVolumeBitmap:(NSData *_Nonnull const)vbmData;

///Create a file in the catalog and return its file ID. Extent start is not guaranteed to be preserved in new volume.
- (u_int32_t) createFileWithExtent:(NSRange)extentRange parent:(u_int32_t)parentDirID;
- (u_int32_t) createFileWithLength:(NSUInteger)length parent:(u_int32_t)parentDirID;
///Append data to the indicated file.
- (void)appendData:(NSData *_Nonnull const)data toFile:(u_int32_t)fileID;

@end
