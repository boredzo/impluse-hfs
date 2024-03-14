//
//  ImpTextEncodingConverter.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-02.
//

#import "ImpTextEncodingConverter.h"

#import "ImpPrintf.h"
#import "ImpByteOrder.h"
#import "ImpErrorUtilities.h"

enum {
	ImpExtFinderFlagsHasEmbeddedScriptCodeMask = 1 << 15,
	ImpExtFinderFlagsScriptCodeMask = 0x7f << 8,
};

@implementation ImpTextEncodingConverter
{
	TextEncoding _hfsTextEncoding, _hfsPlusTextEncoding;
	TextToUnicodeInfo _ttui;
}

+ (NSString *_Nullable) nameOfTextEncoding:(TextEncoding const)enc {
	unsigned char encodingNameBuf[256] = "[no name given]";
	ByteCount encodingNameLen;
	TextEncoding const encodingUTF8 = CreateTextEncoding(kTextEncodingUnicodeDefault, kTextEncodingDefaultVariant, kUnicodeUTF8Format);
	RegionCode actualRegion = -1;
	TextEncoding actualEncoding = -1;
	OSStatus const err = GetTextEncodingName(enc, kTextEncodingFullName,
		//Details of how we want TEC to return this name.
		kTextRegionDontCare, encodingUTF8,
		//Info on the buffer for TEC to copy the name into.
		sizeof(encodingNameBuf) - 1, &encodingNameLen,
		//Outputs.
		&actualRegion, &actualEncoding, encodingNameBuf);
	if (err != noErr) {
//		ImpPrintf(@"    Couldn't get encoding name: %d/%s", err, GetMacOSStatusCommentString(err));
		return nil;
	} else {
		encodingNameBuf[encodingNameLen] = 0;
		NSString *_Nonnull const encodingName = [NSString stringWithUTF8String:(char const *_Nonnull)encodingNameBuf];
		return encodingName;
	}
}

#pragma mark Finder flags parsing

+ (TextEncoding) textEncodingFromExtendedFinderFlags:(UInt16 const)extFinderFlags defaultEncoding:(TextEncoding const)defaultEncoding {
	if ([self hasTextEncodingInExtendedFinderFlags:extFinderFlags]) {
		return [self textEncodingFromExtendedFinderFlags:extFinderFlags];
	} else {
		return defaultEncoding;
	}
}
+ (bool) hasTextEncodingInExtendedFinderFlags:(UInt16 const)extFinderFlags {
	UInt16 const hasEmbeddedScriptCodeBit = (extFinderFlags & ImpExtFinderFlagsHasEmbeddedScriptCodeMask);
	return hasEmbeddedScriptCodeBit;
}
+ (TextEncoding) textEncodingFromExtendedFinderFlags:(UInt16 const)extFinderFlags {
	return (extFinderFlags & ImpExtFinderFlagsScriptCodeMask) >> 8;
}

#pragma mark Conveniences for catalog records

+ (instancetype _Nullable) converterForExtendedFileInfo:(struct ExtendedFileInfo const *_Nonnull const)extFilePtr fallback:(ImpTextEncodingConverter *_Nonnull const)fallbackConverter {
	TextEncoding const fallbackEncoding = fallbackConverter->_hfsTextEncoding;
	TextEncoding const thisEncoding = [self textEncodingFromExtendedFinderFlags:L(extFilePtr->extendedFinderFlags) defaultEncoding:fallbackEncoding];
	if (thisEncoding == fallbackEncoding) {
		return fallbackConverter;
	} else {
		return [ImpTextEncodingConverter converterWithHFSTextEncoding:thisEncoding];
	}
}
+ (instancetype _Nullable) converterForExtendedFolderInfo:(struct ExtendedFolderInfo const *_Nonnull const)extFolderPtr fallback:(ImpTextEncodingConverter *_Nonnull const)fallbackConverter {
	TextEncoding const fallbackEncoding = fallbackConverter->_hfsTextEncoding;
	TextEncoding const thisEncoding = [self textEncodingFromExtendedFinderFlags:L(extFolderPtr->extendedFinderFlags) defaultEncoding:fallbackEncoding];
	if (thisEncoding == fallbackEncoding) {
		return fallbackConverter;
	} else {
		return [ImpTextEncodingConverter converterWithHFSTextEncoding:thisEncoding];
	}
}

///If this file has a script code in its extended Finder flags, creates a converter for that encoding. Otherwise, returns the fallback converter.
+ (instancetype _Nullable) converterForHFSFile:(struct HFSCatalogFile const *_Nonnull const)filePtr fallback:(ImpTextEncodingConverter *_Nonnull const)fallbackConverter {
	return [self converterForExtendedFileInfo:(struct ExtendedFileInfo const *)&(filePtr->finderInfo) fallback:fallbackConverter];
}
///If this folder has a script code in its extended Finder flags, creates a converter for that encoding. Otherwise, returns the fallback converter.
+ (instancetype _Nullable) converterForHFSFolder:(struct HFSCatalogFolder const *_Nonnull const)folderPtr fallback:(ImpTextEncodingConverter *_Nonnull const)fallbackConverter {
	return [self converterForExtendedFolderInfo:(struct ExtendedFolderInfo const *)&(folderPtr->finderInfo) fallback:fallbackConverter];
}

///If this file has a script code in its extended Finder flags, creates a converter for that encoding. Otherwise, returns the fallback converter.
+ (instancetype _Nullable) converterForHFSPlusFile:(struct HFSPlusCatalogFile const *_Nonnull const)filePtr fallback:(ImpTextEncodingConverter *_Nonnull const)fallbackConverter {
	return [self converterForExtendedFileInfo:(struct ExtendedFileInfo const *)&(filePtr->finderInfo) fallback:fallbackConverter];
}
///If this folder has a script code in its extended Finder flags, creates a converter for that encoding. Otherwise, returns the fallback converter.
+ (instancetype _Nullable) converterForHFSPlusFolder:(struct HFSPlusCatalogFolder const *_Nonnull const)folderPtr fallback:(ImpTextEncodingConverter *_Nonnull const)fallbackConverter {
	return [self converterForExtendedFolderInfo:(struct ExtendedFolderInfo const *)&(folderPtr->finderInfo) fallback:fallbackConverter];
}

#pragma mark Factories

+ (instancetype _Nullable) converterWithHFSTextEncoding:(TextEncoding const)hfsTextEncoding {
	static NSMutableDictionary <NSNumber *, ImpTextEncodingConverter *> *_Nullable converterCache = nil;
	if (converterCache == nil) {
		//We're most likely to find MacRoman plus at most one other encoding. More than two encodings should be fairly rare. The NSMutableDictionary initializer will let us go over if we need to.
		converterCache = [NSMutableDictionary dictionaryWithCapacity:2];
	}

	NSNumber *_Nonnull const key = @(hfsTextEncoding);
	ImpTextEncodingConverter *_Nullable thisConverter = converterCache[key];
	if (thisConverter == nil) {
		thisConverter = [[self alloc] initWithHFSTextEncoding:hfsTextEncoding];
		converterCache[key] = thisConverter;
	}

	return thisConverter;

}
///Returns an object that (hopefully) can convert filenames from the given encoding into Unicode.
- (instancetype _Nullable) initWithHFSTextEncoding:(TextEncoding const)hfsTextEncoding {
	if ((self = [super init])) {
		_hfsTextEncoding = hfsTextEncoding;
		_hfsPlusTextEncoding = CreateTextEncoding(kTextEncodingUnicodeV2_0, kUnicodeHFSPlusDecompVariant, kUnicodeUTF16BEFormat);

		struct UnicodeMapping mapping = {
			.unicodeEncoding = _hfsPlusTextEncoding,
			.otherEncoding = _hfsTextEncoding,
			.mappingVersion = kUnicodeUseHFSPlusMapping,
		};
		OSStatus const err = CreateTextToUnicodeInfo(&mapping, &_ttui);
		if (err != noErr) {
			ImpPrintf(@"Failed to initialize Unicode conversion from %x to %x: error %d/%s", _hfsTextEncoding, _hfsPlusTextEncoding, err, ImpExplainOSStatus(err));
		}
	}
	return self;
}

- (instancetype) init {
	NSAssert(false, @"You must use initWithHFSTextEncoding: to properly initialize an ImpTextEncodingConverter.");
	return nil;
}

- (void)dealloc {
	DisposeTextToUnicodeInfo(&_ttui);
}

#pragma mark Size estimation

- (ByteCount) estimateSizeOfHFSUniStr255NeededForPascalString:(ConstStr31Param _Nonnull const)pascalString maxLength:(u_int8_t const)maxLength {
	u_int8_t const srcLength = *pascalString;
	u_int8_t const workingLength = (
		(maxLength > 0 && srcLength > maxLength)
		? maxLength
		: srcLength
	);
	//The length in MacRoman characters may include accented characters that HFS+ decomposition will decompose to a base character and a combining character, so we actually need to double the length *in characters*.
	ByteCount outputPayloadSizeInBytes = (2 * workingLength) * sizeof(UniChar);
	//TECConvertText documentation: “Always allocate a buffer at least 32 bytes long.”
	if (outputPayloadSizeInBytes < 32) {
		outputPayloadSizeInBytes = 32;
	}
	ByteCount const outputBufferSizeInBytes = outputPayloadSizeInBytes + 1 * sizeof(UniChar);
	return outputBufferSizeInBytes;
}
- (ByteCount) estimateSizeOfHFSUniStr255NeededForPascalString:(ConstStr31Param _Nonnull const)pascalString {
	return [self estimateSizeOfHFSUniStr255NeededForPascalString:pascalString maxLength:0];
}

#pragma mark Conversion

- (bool) convertPascalString:(ConstStr31Param _Nonnull const)pascalString maxLength:(u_int8_t const)maxInputLength intoHFSUniStr255:(HFSUniStr255 *_Nonnull const)outUnicode bufferSize:(ByteCount)outputBufferSizeInBytes {
	UniChar *_Nonnull const outputBuf = outUnicode->unicode;

	NSMutableData *_Nullable tempData = nil;
	ConstStr31Param inputStringPtr = pascalString;
	if (maxInputLength > 0 && inputStringPtr[0] > maxInputLength) {
		tempData = [NSMutableData dataWithBytes:pascalString length:maxInputLength + 1];
		StringPtr tempStrPtr = tempData.mutableBytes;
		tempStrPtr[0] = (u_int8_t)maxInputLength;
		inputStringPtr = tempData.bytes;
	}

	ByteCount const outputPayloadSizeInBytes = outputBufferSizeInBytes - 1 * sizeof(UniChar);
	ByteCount actualOutputLengthInBytes = 0;
	OSStatus err = ConvertFromPStringToUnicode(_ttui, pascalString, outputPayloadSizeInBytes, &actualOutputLengthInBytes, outputBuf);

	if (err == paramErr) {
		//Set a breakpoint here to try to step into ConvertFromPStringToUnicode.
		NSLog(@"Unicode conversion failure!");
		err = ConvertFromPStringToUnicode(_ttui, pascalString, outputPayloadSizeInBytes, &actualOutputLengthInBytes, outputBuf);
	}

	if (err == noErr) {
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
		//Swap all the bytes in the output data.
		swab(outputBuf, outputBuf, actualOutputLengthInBytes);
#endif
	} else {
		NSMutableData *_Nonnull const cStringData = [NSMutableData dataWithLength:pascalString[0]];
		char *_Nonnull const cStringBytes = cStringData.mutableBytes;
		memcpy(cStringBytes, pascalString + 1, *pascalString);
		ImpPrintf(@"Failed to convert filename '%s' (length %u) to Unicode: error %d/%s", (char const *)cStringBytes, (unsigned)*pascalString, err, ImpExplainOSStatus(err));
		if (err == kTECOutputBufferFullStatus) {
			ImpPrintf(@"Output buffer full: %lu vs. buffer size %lu", (unsigned long)actualOutputLengthInBytes, outputPayloadSizeInBytes);
		}
		return false;
	}

	S(outUnicode->length, (u_int16_t)(actualOutputLengthInBytes / sizeof(UniChar)));
	return true;
}
- (bool) convertPascalString:(ConstStr31Param _Nonnull const)pascalString intoHFSUniStr255:(HFSUniStr255 *_Nonnull const)outUnicode bufferSize:(ByteCount)outputBufferSizeInBytes {
	return [self convertPascalString:pascalString maxLength:0 intoHFSUniStr255:outUnicode bufferSize:outputBufferSizeInBytes];
}

- (NSData *_Nonnull const)hfsUniStr255ForPascalString:(ConstStr31Param _Nonnull const)pascalString maxLength:(u_int8_t const)maxLength {
	ByteCount const outputBufferSizeInBytes = [self estimateSizeOfHFSUniStr255NeededForPascalString:pascalString maxLength:maxLength];
	NSMutableData *_Nonnull const unicodeData = [NSMutableData dataWithLength:outputBufferSizeInBytes];

	if (*pascalString == 0) {
		//TEC doesn't like converting empty strings, so just return our empty HFSUniStr255 without calling TEC.
		return unicodeData;
	}

	UniChar *_Nonnull const outputBuf = unicodeData.mutableBytes;
	bool const converted = [self convertPascalString:pascalString intoHFSUniStr255:(HFSUniStr255 *)outputBuf bufferSize:outputBufferSizeInBytes];

	return converted ? unicodeData : nil;
}
- (NSData *_Nonnull const)hfsUniStr255ForPascalString:(ConstStr31Param)pascalString {
	return [self hfsUniStr255ForPascalString:pascalString maxLength:31];
}

- (NSString *_Nonnull const) stringForPascalString:(ConstStr31Param)pascalString maxLength:(const u_int8_t)maxLength {
	NSData *_Nonnull const unicodeData = [self hfsUniStr255ForPascalString:pascalString maxLength:maxLength];
	/* This does not seem to work.
	 hfsUniStr255ForPascalString: needs to return UTF-16 BE so we can write it out to HFS+. But if we call CFStringCreateWithPascalString, it seems to always take the host-least-significant byte and treat it as a *byte count*. That basically means this always returns an empty string. If the length is unswapped, it returns the first half of the string.
	NSString *_Nonnull const unicodeString = (__bridge_transfer NSString *)CFStringCreateWithPascalString(kCFAllocatorDefault, unicodeData.bytes, kCFStringEncodingUTF16BE);
	 */
	CFIndex const numCharacters = L(*(UniChar *)unicodeData.bytes);
	NSString *_Nonnull const unicodeString = (__bridge_transfer NSString *)CFStringCreateWithBytes(kCFAllocatorDefault, unicodeData.bytes + sizeof(UniChar), numCharacters * sizeof(UniChar), kCFStringEncodingUTF16BE, /*isExternalRep*/ false);
	return unicodeString;
}
- (NSString *_Nonnull const) stringForPascalString:(ConstStr31Param _Nonnull const)pascalString fromHFSCatalogKey:(struct HFSCatalogKey const *_Nonnull const)keyPtr {
	u_int8_t const keyLength = L(keyPtr->keyLength);
	u_int8_t const subtrahend = sizeof(keyPtr->keyLength) + sizeof(keyPtr->reserved) + sizeof(keyPtr->parentID) + sizeof(keyPtr->nodeName[0]);
	if (subtrahend >= keyLength) {
		return @"";
	}
	u_int8_t const maxLength = keyLength - subtrahend;
	return [self stringForPascalString:pascalString maxLength:maxLength];
}
- (NSString *_Nonnull const) stringForPascalString:(ConstStr31Param)pascalString {
	return [self stringForPascalString:pascalString maxLength:31];
}

- (NSString *_Nonnull const) stringFromHFSUniStr255:(ConstHFSUniStr255Param)unicodeName {
	UInt16 const numCharacters = L(unicodeName->length);

	//Ideally, we'd simply pass _hfsPlusTextEncoding (Unicode 2.0 UTF-16 BE) to CFStringCreateWithBytes and that would Just Work. It does not.
	//Failing that, we might swab and then use this encoding, which at least stays in Unicode 2.0. However, it doesn't work either.
	//	TextEncoding const hfsPlusNativeOrderTextEncoding = CreateTextEncoding(kTextEncodingUnicodeV2_0, kUnicodeHFSPlusDecompVariant, kUnicodeUTF16Format);
	//	NSString *_Nonnull const str = (__bridge_transfer NSString *)CFStringCreateWithBytes(kCFAllocatorDefault, (UInt8 const *_Nonnull)unicodeName->unicode, numBytes, hfsPlusNativeOrderTextEncoding, /*isExternalRepresentation*/ false);
	//So our last resort is to interpret the Unicode 2.0 bytes as modern-Unicode bytes. Your friendly author does not know of any reasons why this is a bad idea. (If any such reasons present themselves, we would need to use TEC to convert the Unicode 2.0 bytes—swabbed or otherwise—to modern Unicode in native order.)

	size_t const numBytes = numCharacters * sizeof(unichar);
	NSMutableData *_Nonnull const charactersData = [NSMutableData dataWithLength:numBytes];
	unichar *_Nonnull const nativeOrderCharacters = charactersData.mutableBytes;
#if __LITTLE_ENDIAN__
	swab(unicodeName->unicode, nativeOrderCharacters, numBytes);
#else
	memcpy(nativeOrderCharacters, unicodeName->unicode, numBytes);
#endif

	NSString *_Nonnull const str = [NSString stringWithCharacters:nativeOrderCharacters length:numCharacters];
	return str;
}

#pragma mark Conversion from NSString

- (bool) convertString:(NSString *_Nonnull const)inStr toHFSUniStr255:(struct HFSUniStr255 *_Nonnull const)outUnicodeName {
	NSUInteger const actualStringLength = inStr.length;
	u_int16_t const cappedStringLength = actualStringLength > 255 ? 255 : (u_int16_t)actualStringLength;
	NSData *_Nonnull const charactersData = [[inStr substringToIndex:cappedStringLength] dataUsingEncoding:NSUTF16BigEndianStringEncoding];
	size_t const numBytes = charactersData.length;
	unichar const *_Nonnull const nativeEndianCharacters = charactersData.bytes;
	memcpy(outUnicodeName->unicode, nativeEndianCharacters, numBytes);
	S(outUnicodeName->length, cappedStringLength);
	return cappedStringLength == actualStringLength;
}

#pragma mark String escaping

- (NSString *_Nonnull const) stringByEscapingString:(NSString *_Nonnull const)inString {
	unichar escapedBuf[1024];
	NSUInteger escapedLen = 0;

	unichar unescapedBuf[256];
	NSUInteger unescapedLen = inString.length;
	[inString getCharacters:unescapedBuf range:(NSRange){ 0, unescapedLen }];

	for (NSUInteger unescapedChIdx = 0; unescapedChIdx < unescapedLen; ++unescapedChIdx) {
		unichar const ch = unescapedBuf[unescapedChIdx];
		switch (ch) {
			case 0:
				escapedBuf[escapedLen++] = '\\';
				escapedBuf[escapedLen++] = '0';
				break;
			case '\b':
				escapedBuf[escapedLen++] = '\\';
				escapedBuf[escapedLen++] = 'b';
				break;
			case '\t':
				escapedBuf[escapedLen++] = '\\';
				escapedBuf[escapedLen++] = 't';
				break;
			case 0xa:
				escapedBuf[escapedLen++] = '\\';
				escapedBuf[escapedLen++] = 'r';
				break;
			case '\v':
				escapedBuf[escapedLen++] = '\\';
				escapedBuf[escapedLen++] = 'v';
				break;
			case '\f':
				escapedBuf[escapedLen++] = '\\';
				escapedBuf[escapedLen++] = 'f';
				break;
			case 0xd:
				escapedBuf[escapedLen++] = '\\';
				escapedBuf[escapedLen++] = 'n';
				break;

			case 0x01:
			case 0x02:
			case 0x03:
			case 0x04:
			case 0x05:
			case 0x06:
			case 0x07:
			case 0x0e:
			case 0x0f:
			case 0x10:
			case 0x11:
			case 0x12:
			case 0x13:
			case 0x14:
			case 0x15:
			case 0x16:
			case 0x17:
			case 0x18:
			case 0x19:
			case 0x1a:
			case 0x1b:
			case 0x1c:
			case 0x1d:
			case 0x1e:
			case 0x1f:
			case 0x7f:
				escapedBuf[escapedLen++] = '\\';
				escapedBuf[escapedLen++] = 'x';
				escapedBuf[escapedLen++] = '0' + ((ch >> 4) & 0xf);
				escapedBuf[escapedLen++] = '0' + ((ch >> 0) & 0xf);
				break;

			default:
				escapedBuf[escapedLen++] = ch;
				break;
		}
	}

	return [NSString stringWithCharacters:escapedBuf length:escapedLen];
}

@end
