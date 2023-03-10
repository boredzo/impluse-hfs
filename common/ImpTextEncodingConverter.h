//
//  ImpTextEncodingConverter.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-02.
//

#import <Foundation/Foundation.h>

@interface ImpTextEncodingConverter : NSObject

///Given a text encoding in the type used by the Text Encoding Converter, return its name. Returns nil if TEC does not return a name for this encoding.
+ (NSString *_Nullable) nameOfTextEncoding:(TextEncoding const)hfsTextEncoding;

#pragma mark -

///Given the extended flags from an ExtendedFileInfo or ExtendedFileInfo structure, return the script code embedded there if it has one, or the supplied default if not.
+ (TextEncoding) textEncodingFromExtendedFinderFlags:(UInt16 const)extFinderFlags defaultEncoding:(TextEncoding const)defaultEncoding;

///Returns whether these extended Finder flags contain an embedded script code.
+ (bool) hasTextEncodingInExtendedFinderFlags:(UInt16 const)extFinderFlags;
///Assuming these extended Finder flags contain an embedded script code, return it. The return value is undefined if the extended Finder flags do not contain an embedded script code.
+ (TextEncoding) textEncodingFromExtendedFinderFlags:(UInt16 const)extFinderFlags;

#pragma mark -

///If this file has a script code in its extended Finder flags, creates a converter for that encoding. Otherwise, returns the fallback converter.
+ (instancetype _Nullable) converterForHFSFile:(struct HFSCatalogFile const *_Nonnull const)filePtr fallback:(ImpTextEncodingConverter *_Nonnull const)fallbackConverter;
///If this folder has a script code in its extended Finder flags, creates a converter for that encoding. Otherwise, returns the fallback converter.
+ (instancetype _Nullable) converterForHFSFolder:(struct HFSCatalogFolder const *_Nonnull const)folderPtr fallback:(ImpTextEncodingConverter *_Nonnull const)fallbackConverter;

///If this file has a script code in its extended Finder flags, creates a converter for that encoding. Otherwise, returns the fallback converter.
+ (instancetype _Nullable) converterForHFSPlusFile:(struct HFSPlusCatalogFile const *_Nonnull const)filePtr fallback:(ImpTextEncodingConverter *_Nonnull const)fallbackConverter;
///If this folder has a script code in its extended Finder flags, creates a converter for that encoding. Otherwise, returns the fallback converter.
+ (instancetype _Nullable) converterForHFSPlusFolder:(struct HFSPlusCatalogFolder const *_Nonnull const)folderPtr fallback:(ImpTextEncodingConverter *_Nonnull const)fallbackConverter;

#pragma mark -

///Returns an object that (hopefully) can convert filenames from the given encoding into Unicode.
+ (instancetype _Nullable) converterWithHFSTextEncoding:(TextEncoding const)hfsTextEncoding;
///Returns an object that (hopefully) can convert filenames from the given encoding into Unicode.
- (instancetype _Nullable) initWithHFSTextEncoding:(TextEncoding const)hfsTextEncoding;

///The encoding this converter was created to convert.
@property(readonly) TextEncoding hfsTextEncoding;

#pragma mark -

///Obtain an estimate of how many bytes might be needed to hold the Unicode conversion of this string, including 2 bytes for the length.
- (ByteCount) estimateSizeOfHFSUniStr255NeededForPascalString:(ConstStr31Param _Nonnull const)pascalString;
///Returns true if the characters were successfully converted; returns false if some characters could not be converted or there wasn't enough space.
- (bool) convertPascalString:(ConstStr31Param _Nonnull const)pascalString intoHFSUniStr255:(HFSUniStr255 *_Nonnull const)outUnicode bufferSize:(ByteCount)outputBufferSizeInBytes;

- (NSData *_Nonnull const)hfsUniStr255ForPascalString:(ConstStr31Param _Nonnull const)pascalString;
- (NSString *_Nonnull const) stringForPascalString:(ConstStr31Param _Nonnull const)pascalString;

- (NSString *_Nonnull const) stringFromHFSUniStr255:(ConstHFSUniStr255Param _Nonnull const)unicodeName;

@end
