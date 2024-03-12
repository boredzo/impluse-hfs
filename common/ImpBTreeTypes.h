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

///B*-tree types defined by TN1150, stored in the header node's btreeType field.
enum {
	BTreeTypeHFS = 0x00,
	BTreeTypeUser = 0x80,
	BTreeTypeReserved = 0xff,
};

///Constants identifying various types of B*-trees, to inform how their contents (particularly keys and leaf node record payloads) should be interpreted, and to aid in converting a tree to a different version of the same kind.
typedef NS_ENUM(NSUInteger, ImpBTreeVersion) {
	ImpBTreeVersionHFSCatalog = 0x001,
	ImpBTreeVersionHFSExtentsOverflow = 0x002,
	//No ImpBTreeVersionHFSAttributes because there is no attributes file in HFS.

	ImpBTreeVersionHFSPlusCatalog = 0x100,
	ImpBTreeVersionHFSPlusExtentsOverflow = 0x200,
	ImpBTreeVersionHFSPlusAttributes = 0x300,
};

