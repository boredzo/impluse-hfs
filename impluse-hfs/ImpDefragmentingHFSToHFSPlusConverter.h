//
//  ImpDefragmentingHFSToHFSPlusConverter.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-10.
//

#import <Foundation/Foundation.h>

#import "ImpHFSToHFSPlusConverter.h"

/*! Implements the defragmenting conversion algorithm for converting HFS volumes to HFS+. This algorithm wreaks bigger changes (every file could end up in a different location on disk) but is also simpler.
 *The defragmenting algorithm is (all steps in memory unless otherwise noted):
 * * Convert the volume header.
 * * Convert the catalog file.
 * * Convert (and likely empty out) the extents overflow file.
 * * Start with an empty allocations bitmap, setting only the bits for the blocks containing the boot blocks, volume header, alternate volume header, and footer.
 * * Create a new catalog file in memory, and convert all of the old catalog entries into it. Maintain the B*-tree hierarchy, but reconnect index nodes' pointer records to their new descendant nodes. Allocate extents as part of the conversion, setting the corresponding bits in the allocations bitmap.
 * * Write one file at a time into the new volume: first writing the allocations file, then the catalog file, then the extents overflow file, then copying the fork contents of every user file and folder, and lastly writing the by-now-populated bitmap into the allocations file.
 * * The very last step is to write the boot blocks and volume headers (both of them) to the new volume. Once this is done and the file closed, Disk Arbitration will attempt to mount the volume. If we did our job right, it'll succeed.
 */
@interface ImpDefragmentingHFSToHFSPlusConverter : ImpHFSToHFSPlusConverter

@end
