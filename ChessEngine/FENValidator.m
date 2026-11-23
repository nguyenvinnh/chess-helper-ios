#import "FENValidator.h"

static BOOL ValidatePlacementChars(NSString *s, NSUInteger start, NSUInteger end) {
    int rankCount = 0;
    int rankSum = 0;
    BOOL hasCharInRank = NO;
    for (NSUInteger i = start; i < end; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == '/') {
            if (!hasCharInRank || rankSum != 8) return NO;
            rankCount++;
            rankSum = 0;
            hasCharInRank = NO;
            continue;
        }
        hasCharInRank = YES;
        if (c >= '1' && c <= '8') rankSum += (c - '0');
        else if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) {
            if (c != 'p' && c != 'n' && c != 'b' && c != 'r' && c != 'q' && c != 'k' &&
                c != 'P' && c != 'N' && c != 'B' && c != 'R' && c != 'Q' && c != 'K') return NO;
            rankSum += 1;
        } else return NO;
        if (rankSum > 8) return NO;
    }
    if (!hasCharInRank || rankSum != 8) return NO;
    return rankCount == 7;
}

@implementation FENValidator

+ (BOOL)isFENString:(NSString *)str {
    if (![str isKindOfClass:[NSString class]]) return NO;
    NSString *s = [str stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSUInteger len = s.length;
    if (len < 20 || len > 100) return NO;
    NSUInteger space = NSNotFound;
    for (NSUInteger i = 0; i < len; i++) {
        if ([s characterAtIndex:i] == ' ') { space = i; break; }
    }
    if (space == NSNotFound || space < 15) return NO;
    if (!ValidatePlacementChars(s, 0, space)) return NO;
    if (space + 1 >= len) return NO;
    unichar turn = [s characterAtIndex:space + 1];
    return turn == 'w' || turn == 'b';
}

+ (BOOL)looksLikeValidBoardLayout:(NSString *)placement {
    if (!placement) return NO;
    NSString *s = [placement stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (s.length < 15) return NO;
    return ValidatePlacementChars(s, 0, s.length);
}

+ (NSString *)normalizedFEN:(NSString *)fen {
    if (!fen) return nil;
    NSString *trimmed = [fen stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return nil;
    NSArray *parts = [trimmed componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSMutableArray *filtered = [NSMutableArray array];
    for (NSString *p in parts) {
        if (p.length > 0) [filtered addObject:p];
    }
    if (filtered.count < 2) return nil;
    if (![self looksLikeValidBoardLayout:filtered[0]]) return nil;
    NSString *turn = filtered[1];
    if (![turn isEqualToString:@"w"] && ![turn isEqualToString:@"b"]) return nil;
    NSUInteger n = MIN(filtered.count, 4);
    return [[filtered subarrayWithRange:NSMakeRange(0, n)] componentsJoinedByString:@" "];
}

+ (NSString *)extractFENFromString:(NSString *)s {
    if (!s || ![s isKindOfClass:[NSString class]]) return nil;
    NSString *trimmed = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([self isFENString:trimmed]) return trimmed;
    NSError *err = nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"[pnbrqkPNBRQK1-8]+(?:/[pnbrqkPNBRQK1-8]+){7} [wb] [KQkq-]+ (?:[a-h][36]|-) \\d+ \\d+" options:0 error:&err];
    NSTextCheckingResult *m = [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    if (m) {
        NSString *cand = [s substringWithRange:m.range];
        if ([self isFENString:cand]) return cand;
    }
    NSRegularExpression *re2 = [NSRegularExpression regularExpressionWithPattern:@"[pnbrqkPNBRQK1-8]+(?:/[pnbrqkPNBRQK1-8]+){7} [wb]" options:0 error:nil];
    NSTextCheckingResult *m2 = [re2 firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    if (m2) {
        NSString *cand2 = [s substringWithRange:m2.range];
        if ([self isFENString:cand2]) return cand2;
    }
    return nil;
}

+ (NSString *)extractFENFromBlob:(id)blob {
    if (!blob) return nil;
    if ([blob isKindOfClass:[NSString class]]) {
        return [self extractFENFromString:(NSString *)blob];
    }
    if ([blob isKindOfClass:[NSData class]]) {
        NSString *s = [[NSString alloc] initWithData:(NSData *)blob encoding:NSUTF8StringEncoding];
        return s ? [self extractFENFromString:s] : nil;
    }
    return nil;
}

@end
