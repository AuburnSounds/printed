/**
Common part of the renderers.

Copyright: Guillaume Piolat 2021.
License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
*/
module printed.canvas.internals;

import std.range, std.traits;


/// Validate line dash pattern. A dash pattern is valid if all values are
/// finite and non-negative.
bool isValidLineDashPattern(float[] segments)
{
    import std.algorithm : all;
    import std.range.primitives;

    return segments.all!(x => 0 <= x && x <= float.infinity);
}


/// Normalize line dash pattern, i.e. the array returned will always have an
/// even number of entries.
///
/// Returns: a copy of segments if the number of entries is even; otherwise
///          the concatenation of segments with itself.
float[] normalizeLineDashPattern(float[] segments)
{
    if (segments.length % 2 == 0)
        return segments.dup;
    else
        return segments ~ segments;
}


public
{
    /// Writes a big endian integer/float to output.
    void writeBE(T, R)(ref R output, T n) if (isOutputRange!(R, ubyte))
    {
        writeFunction!(T, R, false)(output, n);
    }
}

private
{
    // read/write 64-bits float
    union float_uint
    {
        float f;
        uint i;
    }

    // read/write 64-bits float
    union double_ulong
    {
        double f;
        ulong i;
    }

    uint float2uint(float x) pure nothrow
    {
        float_uint fi;
        fi.f = x;
        return fi.i;
    }

    float uint2float(int x) pure nothrow
    {
        float_uint fi;
        fi.i = x;
        return fi.f;
    }

    ulong double2ulong(double x) pure nothrow
    {
        double_ulong fi;
        fi.f = x;
        return fi.i;
    }

    double ulong2double(ulong x) pure nothrow
    {
        double_ulong fi;
        fi.i = x;
        return fi.f;
    }

    private template IntegerLargerThan(int numBytes) if (numBytes >= 1 && numBytes <= 8)
    {
        static if (numBytes == 1)
            alias IntegerLargerThan = ubyte;
        else static if (numBytes == 2)
            alias IntegerLargerThan = ushort;
        else static if (numBytes <= 4)
            alias IntegerLargerThan = uint;
        else
            alias IntegerLargerThan = ulong;
    }

    // Generic integer writing
    void writeInteger(R, int NumBytes, bool LittleEndian)(ref R output, IntegerLargerThan!NumBytes n) if (isOutputRange!(R, ubyte))
    {
        alias T = IntegerLargerThan!NumBytes;

        auto u = cast(Unsigned!T)n;

        static if (LittleEndian)
        {
            for (int i = 0; i < NumBytes; ++i)
            {
                ubyte b = (u >> (i * 8)) & 255;
                output.put(b);
            }
        }
        else
        {
            for (int i = 0; i < NumBytes; ++i)
            {
                ubyte b = (u >> ( (NumBytes - 1 - i) * 8) ) & 255;
                output.put(b);
            }
        }
    }

    void writeFunction(T, R, bool endian)(ref R output, T n) if (isOutputRange!(R, ubyte))
    {
        static if (isIntegral!T)
            writeInteger!(R, T.sizeof, endian)(output, n);
        else static if (is(T : float))
            writeInteger!(R, 4, endian)(output, float2uint(n));
        else static if (is(T : double))
            writeInteger!(R, 8, endian)(output, double2ulong(n));
        else
            static assert(false, "Unsupported type " ~ T.stringof);
    }
}
