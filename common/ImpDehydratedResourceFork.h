//
//  ImpDehydratedResourceFork.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2023-03-20.
//

#import <Foundation/Foundation.h>

@class ImpDehydratedItem;

/*!This is the same NumVersion structure declared in MacTypes.h, except this is the “big-endian” version—the order of these members doesn't actually change in little-endian, and that header's redeclaration of it in the opposite order in little-endian is wrong.
 *While at it, I also took the opportunity to break out the minor and bug-fix members as a bit-field. In that case, the order actually *does* change by endianness, so that part is conditional here.
 *See “Inside Macintosh: Macintosh Toolbox Essentials” chapter 7 (Finder Interface) for more information on the contents of 'vers' resources (defined in MacTypes.h as VersRec), which includes one of these.
 */
struct ImpFixed_NumVersion {
	u_int8_t majorRev; //BCD
#if __LITTLE_ENDIAN__
	//Swapped in little-endian.
	u_int8_t bugFixRev: 4;
	u_int8_t minorRev: 4;
#else
	u_int8_t minorRev: 4;
	u_int8_t bugFixRev: 4;
#endif
	u_int8_t stage; //developStage, alphaStage, betaStage, finalStage
	u_int8_t nonRelRev; //BCD
} __attribute__((packed));

/*!Convert a BCD byte such as the fields of the NumVersion structure into a binary number.
 */
u_int8_t ImpParseBCDByte(u_int8_t byte);

/*!Like ImpFixed_NumVersion, this structure contains fixes from the declaration in MacTypes.h. This version uses the fixed NumVersion structure, and also uses RegionCode rather than a C short for the region code field.
 *The original structure defined two separate members named shortVersionString and longVersionString (or shortVersion and reserved, in the current MacTypes.h), but these cannot be correctly defined as two separate structure members in C.
 *The two version strings are actually variable-length arrays. shortVersionString may be anywhere from 1 byte (a 0x00) to 256 bytes long; however long it is, longVersionString will follow immediately from that point, and likewise is only as big as it needs to be.
 *Hence shortAndLongVersionStrings: It is guaranteed to be at least two bytes (though this is left out here for the sake of declaring it with a C variable-length array member). It is exactly two bytes when both are 0, meaning both strings are empty. Each length byte is followed by the number of bytes so indicated, and no more; the short version string is followed immediately be the long version string's length byte.
 *Two functions are provided to encapsulate the extraction of the two Pascal strings from this one member.
 */
struct ImpFixed_VersRec {
	struct ImpFixed_NumVersion numericVersion;
	RegionCode region;
	unsigned char shortAndLongVersionStrings[];
} __attribute__((packed));

ConstStr255Param _Nonnull ImpGetShortVersionPascalStringFromVersionRecord(struct ImpFixed_VersRec const *_Nonnull const versRec);
ConstStr255Param _Nonnull ImpGetLongVersionPascalStringFromVersionRecord(struct ImpFixed_VersRec const *_Nonnull  const versRec);

@interface ImpDehydratedResourceFork : NSObject

///Returns nil if this resource fork is empty or otherwise does not contain a valid resource header and resource map.
- (instancetype _Nullable) initWithItem:(ImpDehydratedItem *_Nonnull const)item;

///Returns nil if no such resource exists within this resource fork.
- (NSData *_Nullable) resourceOfType:(ResType const)type ID:(ResID const)resID;

#pragma mark Version resource parsing


///Declared for unit test purposes. Given a NumVersion structure (such as one might find in a 'vers' resource), parse its components and assemble a version string from it.
+ (NSString *_Nonnull const) versionStringForNumericVersion:(struct ImpFixed_NumVersion const *_Nonnull const)numericVersion;

@end
