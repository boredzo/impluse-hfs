//
//  ImpDehydratedResourceFork.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2023-03-20.
//

#import "ImpDehydratedResourceFork.h"

#import "ImpHFSVolume.h"
#import "ImpDehydratedItem.h"
#import "ImpTextEncodingConverter.h"

#import "ImpByteOrder.h"
#import "NSData+ImpSubdata.h"

struct ResHeader {
	///The number of bytes from the start of the resource fork to the start of resource data.
	u_int32_t dataOffset;
	///The number of bytes from the start of the resource fork to the start of the resource map.
	u_int32_t mapOffset;
	///The length in bytes of the data section.
	u_int32_t dataLength;
	///The length in bytes of the resource map.
	u_int32_t mapLength;
} __attribute__((aligned(2), packed));

struct ResTypeEntry {
	ResType type;
	ResourceCount numResourcesOfThisTypeMinus1;
	///Number of bytes from beginning of resource types list to the reference list for this type.
	u_int16_t refListOffset;
} __attribute__((aligned(2), packed));

struct ResTypesList {
	///For reasons that are not especially clear, this is stored as the number of types minus 1, which implies that an empty resource fork with a resource map will have -1 here.
	ResourceCount numTypesMinus1;
	struct ResTypeEntry entries[];
} __attribute__((aligned(2), packed));

struct ResReferenceListEntry {
	ResID resourceID;
	///Number of bytes from beginning of resource names list to the name for this resource.
	u_int16_t nameOffset;

	//Yes, this is very weird. IM:MMT (page 1-124) says resourceAttributes is 1 byte and dataOffset is 3. We don't have a 3-byte type, of course, so they get to be 8 bits and 24 bits out of a 32-bit bitfield.
	///Resource attribute bits: resSysHeap, resPurgeable, resLocked, resProtected, resPreload, resChanged
	u_int32_t resourceAttributes : 8;
	///Number of bytes from the beginning of the resource data section to the start of this resource's data.
	u_int32_t dataOffset : 24;

	///Reserved for a ResHandle to this resource. Since we're not using the Resource Manager, this can be ignored.
	u_int32_t resHandle;
} __attribute__((aligned(2), packed));

///This is a Pascal string of no fixed capacity.
struct ResNameEntry {
	u_int8_t length;
	unsigned char name[];
} __attribute__((aligned(1), packed));

struct ResDataEntry {
	///Number of bytes following (i.e., not including) the length.
	u_int32_t length;
	unsigned char bytes[];
} __attribute__((aligned(2), packed));

struct ResMap {
	///A copy of the resource header from the top of the fork.
	struct ResHeader copyOfHeader;
	///Reserved for a Handle to the next resource map in the search path. Not useful on LP64 systems, and the bytes occupying this space on disk should be ignored.
	u_int32_t nextMapHandle;
	///Reserved for the file reference number (Mac-flavored file descriptor) this map is open at. Not relevant to us, since we're not using the Resource Manager.
	SInt16 /*ResFileRefNum*/ refNum;
	///Attribute bits: mapReadOnly, mapCompact, mapChanged
	ResFileAttributes attributes;
	///Number of bytes from beginning of map to list of resource types.
	u_int16_t resTypesListOffset;
	///Number of bytes from beginning of map to list of resource names.
	u_int16_t resNamesListOffset;

	struct ResTypesList typesList;
	//struct ResTypeEntry typesList[];
	//struct ResReferenceListEntry referenceList[];
	//struct ResNameEntry namesList[];
} __attribute__((aligned(2), packed));

enum {
	ImpAbsoluteMinimumResourceForkSize = sizeof(struct ResHeader) + sizeof(struct ResMap),

	ImpResourceNameOffsetNoName = 0xffff,
};

@implementation ImpDehydratedResourceFork
{
	ImpTextEncodingConverter *_Nonnull _textEncodingConverter;

	NSData *_Nonnull _forkData;
	NSData *_Nonnull _resourceData;
	NSData *_Nonnull _resourceMapData;

	void const *_Nonnull _resourceMapStart;
	struct ResMap const *_Nonnull _resourceMap;
	struct ResTypesList const *_Nonnull _typesList;
	struct ResNameEntry const *_Nonnull _namesList;
}

- (instancetype _Nullable) initWithData:(NSData *_Nonnull const)forkData {
	if (forkData.length < ImpAbsoluteMinimumResourceForkSize) {
		//Empty resource fork, not a file, or otherwise not viable to try to parse a resource fork out of.
		return nil;
	} else if ((self = [super init])) {
		//TODO: Get the encoding from the source volume, or from the object driving the operation (e.g., Lister).
		_textEncodingConverter = [ImpTextEncodingConverter converterWithHFSTextEncoding:kTextEncodingMacRoman];
		_forkData = forkData;

		struct ResHeader const *_Nonnull const header = _forkData.bytes;
		NSRange const dataSectionRange = { L(header->dataOffset), L(header->dataLength) };
		NSRange const mapSectionRange = { L(header->mapOffset), L(header->mapLength) };
		if (mapSectionRange.length < sizeof(struct ResMap)) {
			NSLog(@"Insufficient resource map; bailing");
			self = nil;
			return self;
		}

		_resourceData = [_forkData dangerouslyFastSubdataWithRange_Imp:dataSectionRange];
		_resourceMapData = [_forkData dangerouslyFastSubdataWithRange_Imp:mapSectionRange];

		_resourceMapStart = _resourceMapData.bytes;
		_resourceMap = _resourceMapStart;

		_typesList = _resourceMapStart + L(_resourceMap->resTypesListOffset);
		_namesList = _resourceMapStart + L(_resourceMap->resNamesListOffset);
	}
	return self;
}

- (instancetype _Nullable) initWithItem:(ImpDehydratedItem *_Nonnull const)item {
	if (item.resourceForkLogicalLength < ImpAbsoluteMinimumResourceForkSize) {
		//Empty resource fork, not a file, or otherwise not viable to try to parse a resource fork out of.
		return nil;
	} else if ((self = [super init])) {
		NSData *_Nonnull const forkData = [item rehydrateForkContents:ImpForkTypeResource];

		return [self initWithData:forkData];
	}
	return self;
}

///If this type is represented in the resource map, return the number of resources of that type (and, optionally, the pointer to the first reference list entry for it). Returns 0 (and NULL) if there are no such resources.
- (NSUInteger) findResourcesOfType:(ResType const)type getReferenceList:(struct ResReferenceListEntry const *_Nullable *_Nullable const)outRefList {
	ResourceCount const numTypes = L(_resourceMap->typesList.numTypesMinus1) + (ResourceCount)1;
	for (ResourceCount i = 0; i < numTypes; ++i) {
		struct ResTypeEntry const *_Nonnull const typeEntry = _typesList->entries + i;
		ResType const thisType = L(typeEntry->type);

		void const *_Nonnull const typesListStart = _typesList;
		u_int32_t const refListOffset = L(typeEntry->refListOffset);
		//HAX: Why -2???
		struct ResReferenceListEntry const *_Nonnull const refList = typesListStart + refListOffset;

		u_int16_t const numResourcesOfThisType = L(typeEntry->numResourcesOfThisTypeMinus1) + 1;
		/*
		for (UInt16 j = 0; j < numResourcesOfThisType; ++j) {
			printf("%s resource ID %i (0x%04x)\n", NSFileTypeForHFSTypeCode(thisType).UTF8String, L(refList[j].resourceID), L(refList[j].resourceID));
			struct ResNameEntry const *_Nonnull const nameEntry = _namesList + L(refList[j].nameOffset);
			NSString *_Nonnull const name = (__bridge_transfer NSString *)CFStringCreateWithPascalString(kCFAllocatorDefault, (ConstStr255Param)nameEntry, kCFStringEncodingMacRoman);
			printf("\tName: %s\n", name.UTF8String);
		}
		 */

		if (thisType == type) {
			if (outRefList != NULL) {
				*outRefList = refList;
			}
			return numResourcesOfThisType;
		}
	}
	if (outRefList != NULL) {
		*outRefList = NULL;
	}
	return 0;
}

- (NSString *_Nullable const) nameOfResourceOfType:(ResType const)type ID:(ResID const)resID {
	struct ResReferenceListEntry const *_Nullable refList = NULL;
	NSUInteger const numResourcesOfThisType = [self findResourcesOfType:type getReferenceList:&refList];
	if (refList == NULL) {
		return nil;
	}

	for (NSUInteger i = 0; i < numResourcesOfThisType; ++i) {
		struct ResReferenceListEntry const *_Nonnull const refListEntry = refList + i;
		if (L(refListEntry->resourceID) == resID) {
			if (refListEntry->nameOffset == ImpResourceNameOffsetNoName) {
				return nil;
			} else {
				struct ResNameEntry *_Nonnull const resName = ((void *)_namesList) + L(refListEntry->nameOffset);
				return [_textEncodingConverter stringForPascalString:(ConstStr31Param)resName];
			}
		}
	}

	return nil;
}
- (NSData *_Nullable) resourceOfType:(ResType const)type ID:(ResID const)resID {
	if (_forkData.length == 12288) {
		NSLog(@"WARNING: Resource fork contains no resources!!!"); //TEMP
	}
	struct ResReferenceListEntry const *_Nullable refList = NULL;
	NSUInteger const numResourcesOfThisType = [self findResourcesOfType:type getReferenceList:&refList];
	if (refList == NULL) {
		return nil;
	}

	for (NSUInteger i = 0; i < numResourcesOfThisType; ++i) {
		struct ResReferenceListEntry const *_Nonnull const refListEntry = refList + i;
		if (L(refListEntry->resourceID) == resID) {
			u_int32_t const dataEntryOffset = L(refListEntry->dataOffset) >> 8;
			struct ResDataEntry const *_Nonnull const resDataPtr = _resourceData.bytes + dataEntryOffset;
			return [NSData dataWithBytes:resDataPtr->bytes length:L(resDataPtr->length)];
		}
	}

	return nil;
}

#pragma mark Version resource parsing

+ (NSString *_Nonnull const) versionStringForNumericVersion:(struct ImpFixed_NumVersion const *_Nonnull const)numericVersion {
	enum {
		//1.1.1b12345
		ImpVersionStringCapacity = 5 + 1 + 5,
	};
	NSMutableString *_Nonnull const str = [NSMutableString stringWithCapacity:ImpVersionStringCapacity];
	UInt8 const majorRev = ImpParseBCDByte(numericVersion->majorRev);
	UInt8 const minorRev = (numericVersion->minorRev);
	UInt8 const bugRev = (numericVersion->bugFixRev);

	[str appendFormat:@"%d.%d", majorRev, minorRev];
	if (bugRev != 0) {
		[str appendFormat:@".%d", bugRev];
	}

	UInt8 const nonRelRev = numericVersion->nonRelRev;
	if (nonRelRev != 0) {
		NSString *_Nullable stageString = nil;
		unichar stageCharacter = 0;
		switch (numericVersion->stage) {
			case 0:
				stageCharacter = 0;
				break;

			case developStage:
				stageCharacter = 'd';
				break;
			case alphaStage:
				stageCharacter = 'a';
				break;
			case betaStage:
				stageCharacter = 'b';
				break;
			case finalStage:
				stageCharacter = 'r';
				break;

			default:
				stageCharacter = 0x2022; //option-8 bullet
				stageString = [NSString stringWithFormat:@"(•0x%02x)", numericVersion->stage];
				break;
		}
		if (stageCharacter != 0) {
			if (stageCharacter != 0x2022)
			[str appendFormat:@"%C%d", stageCharacter, nonRelRev];
			else
			[str appendFormat:@"%@%d", stageString, nonRelRev];
		}
	}
	return str;
}

@end

u_int8_t ImpParseBCDByte(u_int8_t inputNumber) {
	register UInt8 const highDigit = (inputNumber >> 4) & 0xf;
	register UInt8 const lowDigit = inputNumber & 0xf;
	return highDigit * 10 + lowDigit;
}

ConstStr255Param _Nonnull ImpGetShortVersionPascalStringFromVersionRecord(struct ImpFixed_VersRec const *_Nonnull const versRec) {
	return versRec->shortAndLongVersionStrings;
}
ConstStr255Param _Nonnull ImpGetLongVersionPascalStringFromVersionRecord(struct ImpFixed_VersRec const *_Nonnull const versRec) {
	return versRec->shortAndLongVersionStrings + 1 + versRec->shortAndLongVersionStrings[0];
}
