/**
OpenType/FreeType parsing.

Copyright: Guillaume Piolat 2018.
License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
*/
module printed.font.opentype;

import std.stdio;
import std.conv;
import std.string;
import std.uni;
import std.algorithm.searching;

import binrange;


/// A POD-type to represent a range of Unicode characters.
struct CharRange
{
    dchar start;
    dchar stop;
}

/// Font weight
enum OpenTypeFontWeight : int
{
    thinest = 0, // Note: thinest doesn't exist in PostScript
    thin = 100,
    extraLight = 200,
    light = 300,
    normal = 400,
    medium = 500,
    semiBold = 600,
    bold = 700,
    extraBold = 800,
    black = 900
}

/// Font style
enum OpenTypeFontStyle
{
    normal,
    italic,
    oblique
}

/// Should match printed.canvas `TextBaseline`
enum FontBaseline
{
    top,
    hanging,
    middle,
    alphabetic,
    bottom
}

struct OpenTypeTextMetrics
{
    /// The text's advance width, in glyph units.
    float horzAdvance;
}

/// OpenType 1.8 file parser, for the purpose of finding all fonts in a file, their family name, their weight, etc.
/// This OpenType file might either be:
/// - a single font
/// - a collection file starting with a TTC Header
/// You may find the specification here: www.microsoft.com/typography/otspec/
class OpenTypeFile
{
    this(const(ubyte[]) wholeFileContents)
    {
        _wholeFileData = wholeFileContents;
        const(ubyte)[] file = wholeFileContents[];

        // Read first tag
        uint firstTag = popBE!uint(file);

        if (firstTag == 0x00010000 || firstTag == 0x4F54544F /* 'OTTO' */)
        {
            _isCollection = false;
            _numberOfFonts = 1;
        }
        else if (firstTag == 0x74746366 /* 'ttcf' */)
        {
            _isCollection = true;
            uint version_ = popBE!uint(file); // ignored for now
            _numberOfFonts = popBE!int(file);

            offsetToOffsetTable.length = _numberOfFonts;
            foreach(i; 0.._numberOfFonts)
                offsetToOffsetTable[i] = popBE!uint(file);
        }
        else
            throw new Exception("Couldn't recognize the font file type");
    }

    /// Number of fonts in this OpenType file
    int numberOfFonts()
    {
        return _numberOfFonts;
    }

private:
    const(ubyte)[] _wholeFileData;
    int[] offsetToOffsetTable;

    int _numberOfFonts;
    bool _isCollection; // It is a TTC or single font?

    uint offsetForFont(int index)
    {
        assert(index < numberOfFonts());

        if (_isCollection)
            return offsetToOffsetTable[index];
        else
            return 0;
    }
}


/// Parses a font from a font file (which could contain data for several of them).
class OpenTypeFont
{
public:

    this(OpenTypeFile file, int index)
    {
        _file = file;
        _fontIndex = index;
        _wholeFileData = file._wholeFileData;

        // Figure out font weight, style, and type immediately, as it is useful for font matching

        _isMonospaced = false;

        const(ubyte)[] os2Table = findTable(0x4F532F32 /* 'OS/2' */);
        if (os2Table !is null)
        {
            // Parse weight and style from the 'OS/2' table
            // Note: Apple documentation says that "Many fonts have inaccurate information in their 'OS/2' table."
            // Some fonts don't have this table: https://github.com/princjef/font-finder/issues/5

            skipBytes(os2Table, 4); // table version and xAvgCharWidth
            int usWeightClass = popBE!ushort(os2Table);
            _weight = cast(OpenTypeFontWeight)( 100 * ( (usWeightClass + 50) / 100 ) ); // round to multiple of 100
            skipBytes(os2Table, 2 /*usWidthClass*/  + 2 /*fsType*/ + 10 * 2 /*yXXXXXXX*/ + 2 /*sFamilyClass*/);

            ubyte[10] panose;
            foreach(b; 0..10)
                panose[b] = popBE!ubyte(os2Table);

            _isMonospaced = (panose[0] == 2) && (panose[3] == 9);

            skipBytes(os2Table, 4*4 /*ulUnicodeRangeN*/ + 4/*achVendID*/);
            uint fsSelection = popBE!ushort(os2Table);
            _style = OpenTypeFontStyle.normal;
            if (fsSelection & 1)
                _style = OpenTypeFontStyle.italic;
            if (fsSelection & 512)
                _style = OpenTypeFontStyle.oblique;
        }
        else
        {
            // No OS/2 table? parse 'head' instead (some Mac fonts). For monospace, parse 'post' table.
            const(ubyte)[] postTable = findTable(0x706F7374 /* 'post' */);
            if (postTable)
            {
                skipBytes(postTable, 4 /*version*/ + 4 /*italicAngle*/ + 2 /*underlinePosition*/ + 2 /*underlineThickness*/);
                _isMonospaced = popBE!uint(postTable) /*isFixedPitch*/ != 0;
            }

            const(ubyte)[] headTable = findTable(0x68656164 /* 'head' */);
            if (headTable !is null)
            {
                skipBytes(headTable, 4 /*version*/ + 4 /*fontRevision*/ + 4 /*checkSumAdjustment*/ + 4 /*magicNumber*/ 
                                     + 2 /*flags*/ + 2 /*_unitsPerEm*/ + 16 /*created+modified*/+4*2/*bounding box*/ );
                ushort macStyle = popBE!ushort(headTable);

                _weight = OpenTypeFontWeight.normal;
                if (macStyle & 1) _weight = OpenTypeFontWeight.bold;
                _style = OpenTypeFontStyle.normal;
                if (macStyle & 2) _style = OpenTypeFontStyle.italic;
            }
            else
            {
                // Last chance heuristics.
                // Font weight heuristic based on family names
                string subFamily = subFamilyName().toLower;
                if (subFamily.canFind("thin"))
                    _weight = OpenTypeFontWeight.thin;
                else if (subFamily.canFind("ultra light"))
                    _weight = OpenTypeFontWeight.thinest;
                else if (subFamily.canFind("ultraLight"))
                    _weight = OpenTypeFontWeight.thinest;
                else if (subFamily.canFind("hairline"))
                    _weight = OpenTypeFontWeight.thinest;
                else if (subFamily.canFind("extralight"))
                    _weight = OpenTypeFontWeight.extraLight;
                else if (subFamily.canFind("light"))
                    _weight = OpenTypeFontWeight.light;
                else if (subFamily.canFind("demi bold"))
                    _weight = OpenTypeFontWeight.semiBold;
                else if (subFamily.canFind("semibold"))
                    _weight = OpenTypeFontWeight.semiBold;
                else if (subFamily.canFind("extrabold"))
                    _weight = OpenTypeFontWeight.extraBold;
                else if (subFamily.canFind("bold"))
                    _weight = OpenTypeFontWeight.bold;
                else if (subFamily.canFind("heavy"))
                    _weight = OpenTypeFontWeight.bold;
                else if (subFamily.canFind("medium"))
                    _weight = OpenTypeFontWeight.medium;
                else if (subFamily.canFind("black"))
                    _weight = OpenTypeFontWeight.black;
                else if (subFamily.canFind("negreta"))
                    _weight = OpenTypeFontWeight.black;
                else if (subFamily.canFind("regular"))
                    _weight = OpenTypeFontWeight.normal;
                else if (subFamily == "italic")
                    _weight = OpenTypeFontWeight.normal;
                else
                    _weight = OpenTypeFontWeight.normal;

                // Font style heuristic based on family names
                if (subFamily.canFind("italic"))
                    _style = OpenTypeFontStyle.italic;
                else if (subFamily.canFind("oblique"))
                    _style = OpenTypeFontStyle.oblique;
                else
                    _style = OpenTypeFontStyle.normal;
            }
        }        
    }

    /// Returns: a typographics family name suitable for grouping fonts per family in menus
    string familyName()
    {
        string family = getName(NameID.preferredFamily);
        if (family is null)
            return getName(NameID.fontFamily);
        else
            return family;
    }

    /// Returns: a typographics sub-family name suitable for grouping fonts per family in menus
    string subFamilyName()
    {
        string family = getName(NameID.preferredSubFamily);
        if (family is null)
            return getName(NameID.fontSubFamily);
        else
            return family;
    }

    /// Returns: the PostScript name of that font, if available.
    string postScriptName()
    {
        return getName(NameID.postscriptName);
    }

    /// Returns: the "full" font name, if available.
    string fullFontName()
    {
        return getName(NameID.fullFontName);
    }

    /// Returns: `true` is the font is monospaced.
    bool isMonospaced()
    {
        return _isMonospaced;
    }

    /// Returns: Font weight.
    OpenTypeFontWeight weight()
    {
        return _weight;
    }

    /// Returns: Font style.
    OpenTypeFontStyle style()
    {
        return _style;
    }

    /// Returns: The whole OpenType file where this font is located.
    const(ubyte)[] fileData()
    {
        return _wholeFileData;
    }

    int[4] boundingBox()
    {
        computeFontMetrics();
        return _boundingBox;
    }

    /// Returns: Baseline offset above the normal "alphabetical" baseline.
    ///          In glyph units.
    float getBaselineOffset(FontBaseline baseline)
    {
        computeFontMetrics();
        final switch(baseline) with (FontBaseline)
        {
            case top:
                // ascent - descent should give the em square, but if it doesn't rescale to have top of em square
                float actualUnits = _ascender - _descender;
                return _ascender * _unitsPerEm / actualUnits;

            case hanging:
                return ascent(); // TODO: correct?

            case middle:
                // middle of em square
                float actualUnits = _ascender - _descender;
                return 0.5f * (_ascender + _descender) * _unitsPerEm / actualUnits;

            case alphabetic: 
                return 0; // the default "baseline"

            case bottom:
                // ascent - descent should give the em square, but if it doesn't rescale to have bottom of em square
                float actualUnits = _ascender - _descender;
                return _descender * _unitsPerEm / actualUnits;
        }
    }

    /// Returns: Maximum height above the baseline reached by glyphs in this font.
    ///          In glyph units.
    int ascent()
    {
        computeFontMetrics();
        return _ascender;
    }

    /// Returns: Maximum depth below the baseline reached by glyphs in this font.
    ///          Should be negative.
    ///          In glyph units.
    int descent()
    {
        computeFontMetrics();
        return _descender;
    }

    /// Returns: The spacing between baselines of consecutive lines of text.
    ///          In glyph units.
    ///          Also called "leading".
    int lineGap()
    {
        computeFontMetrics();
        return _ascender - _descender + _lineGap;
    }

    /// Returns: 'A' height.
    /// TODO: eventually extract from OS/2 table
    int capHeight()
    {
        computeFontMetrics();
        return _ascender; // looks like ascent, but perhaps not
    }

    /// Returns: Italic angle in counter-clockwise degrees from the vertical. 
    /// Zero for upright text, negative for text that leans to the right (forward).
    float postScriptItalicAngle()
    {
        computeFontMetrics();
        return _italicAngle / 65536.0f;
    }

    /// Does this font has a glyph for this codepoint?
    bool hasGlyphFor(dchar ch)
    {
        computeFontMetrics();
        ushort* index = ch in _charToGlyphMapping;
        return index !is null;
    }

    ushort glyphIndexFor(dchar ch)
    {
        computeFontMetrics();
        ushort* index = ch in _charToGlyphMapping;
        if (index)
            return *index;
        else
            return 0; // special value for non available characters
    }

    /// Return the glyph used when a char is requested that the font doesn't provide.
    GlyphDesc glyphForChar(dchar ch)
    {
        ushort index = glyphIndexFor(ch);
        if (index != 0)
            return _glyphs[index];

        // Unicode has two symbols for unknown characters:
        // U+25A1 and U+FFFD
        // Browsers seem to use U+FFFD.
        
        index = glyphIndexFor('\uFFFD');
        if (index != 0)
            return _glyphs[index];

        // try 0x7f character (Webdings...)
        index = glyphIndexFor('\u007f');
        if (index != 0)
            return _glyphs[index];

        // try ? character
        index = glyphIndexFor('\u003F');
        if (index != 0)
            return _glyphs[index];

        // try space character
        index = glyphIndexFor(' ');
        if (index != 0)
            return _glyphs[index];

        // Return first glyph.
        if (_glyphs.length > 0)
            return _glyphs[0];

        // give up, this font has no suitable replacement character
        assert(false);
    }

    /// Returns: left side bearing for this character.
    int leftSideBearing(dchar ch)
    {
        computeFontMetrics();
        return glyphForChar(ch).leftSideBearing;
    }

    /// Returns: horizontal advance for this character.
    int horizontalAdvance(dchar ch)
    {
        computeFontMetrics();
        return glyphForChar(ch).horzAdvance;
    }

    /// Returns: number of glyphs in the font.
    int numGlyphs()
    {
        computeFontMetrics();
        return cast(int)(_glyphs.length);
    }

    /// Returns: horizontal advance for a glyph.
    /// In glyph units.
    int horizontalAdvanceForGlyph(int glyphIndex)
    {
        computeFontMetrics();
        return _glyphs[glyphIndex].horzAdvance;
    }

    /// maximum Unicode char available in this font
    dchar maxAvailableChar()
    {
        computeFontMetrics();
        return _maxCodepoint;
    }

    const(CharRange)[] charRanges()
    {
        return _charRanges;
    }

    // The number of internal units for 1em
    float UPM()
    {
        return _unitsPerEm;
    }

    // A scale factpr to convert from glyph units to em
    float invUPM()
    {
        return 1.0f / _unitsPerEm;
    }

    /// Returns text metrics for this piece of text (single line assumed), in glyph units.
    OpenTypeTextMetrics measureText(string text)
    {
        OpenTypeTextMetrics result;
        double sum = 0;
        foreach(dchar ch; text)
            sum += horizontalAdvance(ch);
        result.horzAdvance = sum;
        return result;
    }

private:
    // need whole file since some data may be shared across fonts
    // And also table offsets are relative to the whole file.
    const(ubyte)[] _wholeFileData;

    OpenTypeFile _file;
    int _fontIndex;

    // Computed in constructor
    OpenTypeFontWeight _weight;
    OpenTypeFontStyle _style;
    bool _isMonospaced;

    // <parsed-by-computeFontMetrics>

    bool metricsParsed = false;

    // xmin ymin xmax ymax
    int[4] _boundingBox;

    int _unitsPerEm;

    short _ascender, _descender, _lineGap;
    int _italicAngle; // fixed 16.16 format

    static struct GlyphDesc
    {
        ushort horzAdvance;
        short leftSideBearing;
    }
    GlyphDesc[] _glyphs;

    /// Unicode char to glyph mapping, parsed from 'cmap' table
    /// Note: it's not sure at all if parsing the 'cmap' table each time is more costly.
    /// Also this could be an array sorted by dchar.
    ushort[dchar] _charToGlyphMapping;

    CharRange[] _charRanges;

    dchar _maxCodepoint;

    // </parsed-by-computeFontMetrics>

    /// Returns: A bounding box for each glyph, in glyph space.
    void computeFontMetrics()
    {
        if (metricsParsed)
            return;
        metricsParsed = true;

        const(ubyte)[] headTable = getTable(0x68656164 /* 'head' */);

        skipBytes(headTable, 4); // Table version number
        skipBytes(headTable, 4); // fontRevision
        skipBytes(headTable, 4); // checkSumAdjustment
        uint magicNumber = popBE!uint(headTable);
        if (magicNumber != 0x5F0F3CF5)
            throw new Exception("Invalid magicNumber in 'head' table.");
        skipBytes(headTable, 2); // flags
        _unitsPerEm = popBE!ushort(headTable);
        skipBytes(headTable, 8); // created
        skipBytes(headTable, 8); // modified
        _boundingBox[0] = popBE!short(headTable);
        _boundingBox[1] = popBE!short(headTable);
        _boundingBox[2] = popBE!short(headTable);
        _boundingBox[3] = popBE!short(headTable);
        skipBytes(headTable, 2); // macStyle
        skipBytes(headTable, 2); // lowestRecPPEM
        skipBytes(headTable, 2); // fontDirectionHint
        skipBytes(headTable, 2); // indexToLocFormat
        skipBytes(headTable, 2); // glyphDataFormat

        const(ubyte)[] hheaTable = getTable(0x68686561 /* 'hhea' */);
        skipBytes(hheaTable, 4); // Table version number
        _ascender = popBE!short(hheaTable);
        _descender = popBE!short(hheaTable);
        _lineGap = popBE!short(hheaTable);
        skipBytes(hheaTable, 2); // advanceWidthMax
        skipBytes(hheaTable, 2); // minLeftSideBearing
        skipBytes(hheaTable, 2); // minRightSideBearing
        skipBytes(hheaTable, 2); // xMaxExtent
        skipBytes(hheaTable, 2); // caretSlopeRise
        skipBytes(hheaTable, 2); // caretSlopeRun
        skipBytes(hheaTable, 2); // caretOffset
        skipBytes(hheaTable, 8); // reserved
        short metricDataFormat = popBE!short(hheaTable);
        if (metricDataFormat != 0)
            throw new Exception("Unsupported metricDataFormat in 'hhea' table");

        int numberOfHMetrics = popBE!ushort(hheaTable);

        const(ubyte)[] maxpTable = getTable(0x6D617870 /* 'maxp' */);
        skipBytes(maxpTable, 4); // version
        int numGlyphs = popBE!ushort(maxpTable);

        _glyphs.length = numGlyphs;

        const(ubyte)[] hmtxTable = getTable(0x686D7478 /* 'hmtx' */);

        ushort lastAdvance = 0;
        foreach(g; 0..numberOfHMetrics)
        {
            lastAdvance = popBE!ushort(hmtxTable);
            _glyphs[g].horzAdvance = lastAdvance;
            _glyphs[g].leftSideBearing = popBE!short(hmtxTable);
        }
        foreach(g; numberOfHMetrics.._glyphs.length)
        {
            _glyphs[g].horzAdvance = lastAdvance;
            _glyphs[g].leftSideBearing = popBE!short(hmtxTable);
        }

        // Parse italicAngle
        const(ubyte)[] postTable = getTable(0x706F7374 /* 'post' */);
        skipBytes(postTable, 4); // version
        _italicAngle = popBE!int(postTable);

        parseCMAP();
    }

    /// Parses all codepoints-to-glyph mappings, fills the hashmap `_charToGlyphMapping`
    void parseCMAP()
    {
        const(ubyte)[] cmapTableFull = getTable(0x636d6170 /* 'cmap' */);
        const(ubyte)[] cmapTable = cmapTableFull;

        skipBytes(cmapTable, 2); // version
        int numTables = popBE!ushort(cmapTable);

        // Looking for a BMP Unicode 'cmap' only
        for(int table = 0; table < numTables; ++table)
        {
            ushort platformID = popBE!ushort(cmapTable);
            ushort encodingID = popBE!ushort(cmapTable);
            uint offset = popBE!uint(cmapTable);

            // in stb_truetype, only case supported, seems to be common
            // Unfortunately documentation is scarce about these table formats.
            if (platformID == 3 && (encodingID == 0 /* Unicode 1.0 */
                                 || encodingID == 1 /* Unicode UCS-2 */
                                 || encodingID == 4 /* Unicode UCS-4 */))
            {
                const(ubyte)[] subTable = cmapTableFull[offset..$];
                ushort format = popBE!ushort(subTable);

                // TODO: support other format because this only works within the BMP
                if (format == 4)
                {
                    ushort len = popBE!ushort(subTable);
                    skipBytes(subTable, 2); // language, not useful here
                    int segCountX2 = popBE!ushort(subTable);
                    if ((segCountX2 % 2) != 0)
                        throw new Exception("segCountX2 is not an even number");
                    int segCount = segCountX2/2;
                    int searchRange = popBE!ushort(subTable);
                    int entrySelector = popBE!ushort(subTable);
                    int rangeShift = popBE!ushort(subTable);

                    int[] endCount = new int[segCount];
                    int[] startCount = new int[segCount];
                    short[] idDelta = new short[segCount];

                    int[] idRangeOffset = new int[segCount];

                    foreach(seg; 0..segCount)
                        endCount[seg] = popBE!ushort(subTable);
                    skipBytes(subTable, 2); // reserved, should be zero

                    foreach(seg; 0..segCount)
                        startCount[seg] = popBE!ushort(subTable);

                    foreach(seg; 0..segCount)
                        idDelta[seg] = popBE!short(subTable);

                    const(ubyte)[] idRangeOffsetArray = subTable;

                    foreach(seg; 0..segCount)
                        idRangeOffset[seg] = popBE!ushort(subTable);

                    foreach(seg; 0..segCount)
                    {
                        _charRanges ~= CharRange(startCount[seg], endCount[seg]);

                        foreach(dchar ch; startCount[seg]..endCount[seg])
                        {
                            ushort glyphIndex;

                            if (idRangeOffset[seg] == 0)
                            {
                                glyphIndex = cast(ushort)( cast(ushort)ch + idDelta[seg] );
                            }
                            else
                            {
                                if ((idRangeOffset[seg] % 2) != 0)
                                    throw new Exception("idRangeOffset[i] is not an even number");

                                // Yes, this is what the spec says to do
                                ushort* p = cast(ushort*)(idRangeOffsetArray.ptr);
                                p = p + seg;
                                p = p + (ch - startCount[seg]);
                                p = p + (idRangeOffset[seg]/2);    
                                ubyte[] pslice = cast(ubyte[])(p[0..1]);
                                glyphIndex = popBE!ushort(pslice);

                                if (glyphIndex == 0) // missing glyph
                                    continue;
                                glyphIndex += idDelta[seg];
                            }

                            if (glyphIndex >= _glyphs.length)
                            {
                                throw new Exception("Non existing glyph index");
                            }
                            _charToGlyphMapping[ch] = glyphIndex;

                            if (ch > _maxCodepoint) 
                                _maxCodepoint = ch;
                        }
                    }
                }
                else
                    throw new Exception("Unsupported 'cmap' format");
                break;
            }
        }
    }

    /// Returns: an index in the file, where that table start for this particular font.
    const(ubyte)[] findTable(uint fourCC)
    {
        int offsetToOffsetTable = _file.offsetForFont(_fontIndex);
        const(ubyte)[] offsetTable = _wholeFileData[offsetToOffsetTable..$];

        uint firstTag = popBE!uint(offsetTable);

        if (firstTag != 0x00010000 && firstTag != 0x4F54544F /* 'OTTO' */)
            throw new Exception("Unrecognized tag in Offset Table");

        int numTables = popBE!ushort(offsetTable);
        skipBytes(offsetTable, 6);

        const(uint)[] tableRecordEntries = cast(uint[])(offsetTable[0..16*numTables]);

        // Binary search following
        // https://en.wikipedia.org/wiki/Binary_search_algorithm#Algorithm
        int L = 0;
        int R = numTables - 1;
        while (L <= R)
        {
            int m = (L+R)/2;
            uint tag = forceBigEndian(tableRecordEntries[m * 4]);
            if (tag < fourCC)
                L = m + 1;
            else if (tag > fourCC)
                R = m - 1;
            else
            {
                // found
                assert (tag == fourCC);
                uint checkSum = forceBigEndian(tableRecordEntries[m*4+1]);
                uint offset = forceBigEndian(tableRecordEntries[m*4+2]);
                uint len = forceBigEndian(tableRecordEntries[m*4+3]);
                return _wholeFileData[offset..offset+len];
            }
        }
        return null; // not found
    }

    /// Ditto, but throw if not found.
    const(ubyte)[] getTable(uint fourCC)
    {
        const(ubyte)[] result = findTable(fourCC);
        if (result is null)
            throw new Exception(format("Table not found: %s", fourCC));
        return result;
    }

    /// Returns: that "name" information, in UTF-8
    string getName(NameID requestedNameID)
    {
        const(ubyte)[] nameTable = getTable(0x6e616d65 /* 'name' */);
        const(ubyte)[] nameTableParsed = nameTable;

        ushort format = popBE!ushort(nameTableParsed);
        if (format > 1)
            throw new Exception("Unrecognized format in 'name' table");

        ushort numNameRecords = popBE!ushort(nameTableParsed);
        ushort stringOffset = popBE!ushort(nameTableParsed);

        const(ubyte)[] stringDataStorage = nameTable[stringOffset..$];

        foreach(i; 0..numNameRecords)
        {
            PlatformID platformID = cast(PlatformID) popBE!ushort(nameTableParsed);
            ushort encodingID = popBE!ushort(nameTableParsed);
            ushort languageID = popBE!ushort(nameTableParsed);
            ushort nameID = popBE!ushort(nameTableParsed);
            ushort length = popBE!ushort(nameTableParsed);
            ushort offset = popBE!ushort(nameTableParsed); // String offset from start of storage area (in bytes)
            if (nameID == requestedNameID)
            {
                // found
                const(ubyte)[] stringSlice = stringDataStorage[offset..offset+length];
                string name;

                if (platformID == PlatformID.macintosh && encodingID == 0)
                {
                    // MacRoman encoding
                    name = decodeMacRoman(stringSlice);
                }
                else
                {
                    // Most of the time it's UTF16-BE
                    name = decodeUTF16BE(stringSlice);
                }
                return name;
            }
        }

        return null; // not found
    }

    enum PlatformID : ushort
    {
        unicode,
        macintosh,
        iso,
        windows,
        custom,
    }

    enum NameID : ushort
    {
        copyrightNotice      = 0,
        fontFamily           = 1,
        fontSubFamily        = 2,
        uniqueFontIdentifier = 3,
        fullFontName         = 4,
        versionString        = 5,
        postscriptName       = 6,
        trademark            = 7,
        manufacturer         = 8,
        designer             = 9,
        description          = 10,
        preferredFamily      = 16,
        preferredSubFamily   = 17,
    }
}


private:

uint forceBigEndian(ref const(uint) x) pure nothrow @nogc
{
    version(BigEndian)
        return x;
    else
    {
        import core.bitop: bswap;
        return bswap(x);
    }
}

string decodeMacRoman(const(ubyte)[] input) pure
{
    static immutable dchar[128] CONVERT_TABLE  =
    [
        'Ä', 'Å', 'Ç', 'É', 'Ñ', 'Ö', 'Ü', 'á', 'à', 'â', 'ä'   , 'ã', 'å', 'ç', 'é', 'è',
        'ê', 'ë', 'í', 'ì', 'î', 'ï', 'ñ', 'ó', 'ò', 'ô', 'ö'   , 'õ', 'ú', 'ù', 'û', 'ü',
        '†', '°', '¢', '£', '§', '•', '¶', 'ß', '®', '©', '™'   , '´', '¨', '≠', 'Æ', 'Ø',
        '∞', '±', '≤', '≥', '¥', 'µ', '∂', '∑', '∏', 'π', '∫'   , 'ª', 'º', 'Ω', 'æ', 'ø',
        '¿', '¡', '¬', '√', 'ƒ', '≈', '∆', '«', '»', '…', '\xA0', 'À', 'Ã', 'Õ', 'Œ', 'œ',
        '–', '—', '“', '”', '‘', '’', '÷', '◊', 'ÿ', 'Ÿ', '⁄'   , '€', '‹', '›', 'ﬁ', 'ﬂ',
        '‡', '·', '‚', '„', '‰', 'Â', 'Ê', 'Á', 'Ë', 'È', 'Í'   , 'Î', 'Ï', 'Ì', 'Ó', 'Ô',
        '?', 'Ò', 'Ú', 'Û', 'Ù', 'ı', 'ˆ', '˜', '¯', '˘', '˙'   , '˚', '¸', '˝', '˛', 'ˇ',
    ];

    string textTranslated = "";
    foreach(i; 0..input.length)
    {
        char c = input[i];
        dchar ch;
        if (c < 128)
            ch = c;
        else
            ch = CONVERT_TABLE[c - 128];
        textTranslated ~= ch;
    }
    return textTranslated;
}

string decodeUTF16BE(const(ubyte)[] input) pure
{
    wstring utf16 = "";

    if ((input.length % 2) != 0)
        throw new Exception("Couldn't decode UTF-16 string");

    int numCodepoints = cast(int)(input.length)/2;
    for (int i = 0; i < numCodepoints; ++i)
    {
        wchar ch = popBE!ushort(input);
        utf16 ~= ch;
    }
    return to!string(utf16);
}
