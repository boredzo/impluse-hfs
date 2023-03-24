//
//  ImpCSVProducer.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2023-03-23.
//

#import "ImpCSVProducer.h"

@interface ImpCSVProducer ()

@property(readwrite, copy) NSString *_Nonnull lastRowWritten;

@end

@implementation ImpCSVProducer
{
	NSFileHandle *_Nonnull _outputFH;
	NSArray <NSString *> *_Nonnull _headerRow;
	NSString *_Nonnull _crlf;
	NSUInteger _numColumns;
}

- (instancetype _Nonnull)initWithFileHandle:(NSFileHandle *_Nonnull const)outputFH headerRow:(NSArray<NSString *> *_Nonnull const)headerRow {
	NSParameterAssert(headerRow.count > 0);
	if ((self = [super init])) {
		_outputFH = outputFH;
		_headerRow = [headerRow copy];
		_numColumns = _headerRow.count;
		_crlf = @"\x0d\x0a";

		[self writeRow:_headerRow];
	}
	return self;
}

- (instancetype _Nonnull) initForTestingPurposesWithHeaderRow:(NSArray <NSString *> *_Nonnull const)headerRow {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
	return [self initWithFileHandle:nil headerRow:headerRow];
#pragma clang diagnostic pop
}

- (NSString *_Nonnull const) escapeValue:(NSString *_Nonnull const)value {
	bool const hasQuotes = [value containsString:@"\""];
	bool const hasCommas = [value containsString:@","];
	NSString *_Nonnull const quotesReplaced = hasQuotes ? [value stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""] : value;
	NSString *_Nonnull const quotesAdded = (hasQuotes || hasCommas) ? [NSString stringWithFormat:@"\"%@\"", quotesReplaced] : quotesReplaced;
	return quotesAdded;
}

- (void) writeRow:(NSArray<NSString *> *const)unescapedRow {
	//https://www.rfc-editor.org/rfc/rfc4180
	NSParameterAssert(unescapedRow.count == _numColumns);

	NSMutableArray *_Nonnull const escapedRow = [NSMutableArray arrayWithCapacity:_numColumns];
	for (NSString *_Nonnull const unescapedValue in unescapedRow) {
		NSString *_Nonnull const escapedValue = [self escapeValue:unescapedValue];
		[escapedRow addObject:escapedValue];
	}

	NSString *_Nonnull const line = [[escapedRow componentsJoinedByString:@","] stringByAppendingString:_crlf];
	[_outputFH writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
	_lastRowWritten = line;
}

@end
