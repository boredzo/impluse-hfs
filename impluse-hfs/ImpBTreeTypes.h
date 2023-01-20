//
//  ImpBTreeTypes.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2023-01-06.
//

///Symbolic type name for the type used for the kind field of a B*-tree node's node descriptor.
typedef int8_t BTreeNodeKind;
///Symbolic type name for the type used for the record offsets in the stack at the end of a B*-tree node.
typedef u_int16_t BTreeNodeOffset;

///Minimum node sizes by tree version. Note that in HFS+, node sizes can be larger than these values, just not smaller.
enum {
	BTreeNodeLengthHFSStandard = 0x200 * 1,

	BTreeNodeLengthHFSPlusCatalogMinimum = kHFSPlusCatalogMinNodeSize,
	BTreeNodeLengthHFSPlusExtentsOverflowMinimum = kHFSPlusExtentMinNodeSize,
	BTreeNodeLengthHFSPlusAttributesMinimum = kHFSPlusAttrMinNodeSize,
};
