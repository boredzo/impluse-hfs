//
//  ImpForkUtilities.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-02.
//

#ifndef ImpForkUtilities_h
#define ImpForkUtilities_h

typedef NS_ENUM(u_int8_t, ImpForkType) {
	ImpForkTypeData = 0x00,
	ImpForkTypeResource = 0xff,
};

#endif /* ImpForkUtilities_h */
