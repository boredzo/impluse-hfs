//
//  NSData+ImpHexDump.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-01.
//

#import "NSData+ImpHexDump.h"

@implementation NSData (ImpHexDump)

- (NSString *_Nonnull const) hexDump_Imp {
	enum { bytesPerLine = 8 };
	char postByteTerminators[bytesPerLine] = {
		' ', ' ', ' ', ' ',
		' ', ' ', ' ', '\n',
	};
	NSUInteger terminatorIdx = 0;
	NSUInteger const numBytes = self.length;
	NSMutableString *_Nonnull const hexDump = [NSMutableString stringWithCapacity:numBytes * 3];
	unsigned char const *_Nonnull const bytesPtr = self.bytes;
	for (NSUInteger i = 0; i < numBytes; ++i) {
		[hexDump appendFormat:@"%02x%c", bytesPtr[i], postByteTerminators[terminatorIdx++]];
		if (terminatorIdx >= bytesPerLine) {
			terminatorIdx = 0;
		}
	}
	[hexDump replaceCharactersInRange:(NSRange){ hexDump.length - 1, 1 } withString:@"\n" ];
	return hexDump;
}

@end
