//
//  ImpForkUtilities.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-02.
//

#ifndef ImpForkUtilities_h
#define ImpForkUtilities_h

typedef NS_ENUM(u_int8_t, ImpForkType) {
	//These two match what is documented (unfortunately without constants) in the extent key structures in hfs_format.h.
	ImpForkTypeData = 0x00,
	ImpForkTypeResource = 0xff,

	///ImpForkType's constants are used for a few things, including giving names to the values used in on-disk structures, but in ImpHFSPlusVolume, all three constants may also be used to strategize extent placement.
	///A potential feature would be to place special files (the catalog file, extents overflow file, etc.) earliest in the disk, followed by resource forks (which are small and likely to be accessed frequently and in batches), and data forks last in the disk (because they are large and likely to be accessed rarely).
	///This may or may not be a worthwhile optimization, but as part of making it possible, we declare an additional fork type for internal ImpHFSPlusVolume usage.
	ImpForkTypeSpecialFileContents = 0x01,
};

#endif /* ImpForkUtilities_h */
