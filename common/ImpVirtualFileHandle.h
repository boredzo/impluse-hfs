//
//  ImpVirtualFileHandle.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2024-03-07.
//

#import <Foundation/Foundation.h>

#import <hfs/hfs_format.h>

@class ImpDestinationVolume;

///This is a simple file-handle-like object for writing to files within the HFS+ volume. Writes may be buffered, but ultimately will hit the real backing file via the volume's file descriptor.
@interface ImpVirtualFileHandle : NSObject

///Create a new virtual file handle backed by a destination volume (and its backing file descriptor). extentRecPtr must be a pointer to a populated HFS+ extent record (at least kHFSPlusExtentDensity extent descriptors).
- (instancetype _Nonnull) initWithVolume:(ImpDestinationVolume *_Nonnull const)dstVol extents:(struct HFSPlusExtentDescriptor const *_Nonnull const)extentRecPtr;

///The total size of all blocks in all extents currently backing this file handle. This is the limit of how much data you can write to this file handle.
@property u_int64_t totalPhysicalSize;

///If the file in question has even more extents in the extents overflow file, call this to extend the file handle's knowledge of where it can write data into.
- (void) growIntoExtents:(struct HFSPlusExtentDescriptor const *_Nonnull const)extentRecPtr;

///Write some data to the file. The new data will be appended immediately after any data previously written to the same file handle. Returns the number of bytes written, or -1 in case of error. If this returns zero (or otherwise less data than you tried to write), the file handle's backing extents are full and you need to grow the handle into more extents to be able to write more data.
- (NSInteger) writeData:(NSData *_Nonnull const)data error:(NSError *_Nullable *_Nonnull const)outError;

///Flush any pending writes and bar any further writes.
- (void) closeFile;

@end
