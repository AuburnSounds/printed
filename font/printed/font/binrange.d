/**
Parsing helpers.

Copyright: Guillaume Piolat 2018-2024.
License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
*/
module printed.font.binrange;

import std.range.primitives;
import std.traits;


public
{
    void skipBytes(R)(ref R input, int numBytes) if (isInputRange!R)
    {
        for (int i = 0; i < numBytes; ++i)
            popUbyte(input);
    }

    // Reads a big endian integer from input.
    T popBE(T, R)(ref R input) if (isInputRange!R)
    {
        return popFunction!(T, R, false)(input);
    }

    // Reads a little endian integer from input.
    T popLE(T, R)(ref R input) if (isInputRange!R)
    {
        return popFunction!(T, R, true)(input);
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

    ubyte popUbyte(R)(ref R input) if (isInputRange!R)
    {
        if (input.empty)
            throw new Exception("Expected a byte, but found end of input");

        ubyte b = input.front;
        input.popFront();
        return b;
    }

    // Generic integer parsing
    auto popInteger(R, int NumBytes, bool WantSigned, bool LittleEndian)(ref R input) if (isInputRange!R)
    {
        alias T = IntegerLargerThan!NumBytes;

        T result = 0;

        static if (LittleEndian)
        {
            for (int i = 0; i < NumBytes; ++i)
                result |= ( cast(T)(popUbyte(input)) << (8 * i) );
        }
        else
        {
            for (int i = 0; i < NumBytes; ++i)
                result = cast(T)(result << 8) | popUbyte(input);
        }

        static if (WantSigned)
            return cast(Signed!T)result;
        else
            return result;
    }

    T popFunction(T, R, bool endian)(ref R input) if (isInputRange!R)
    {
        static if(isIntegral!T)
            return popInteger!(R, T.sizeof, isSigned!T, endian)(input);
        else static if (is(T == float))
            return uint2float(popInteger!(R, 4, false, endian)(input));
        else static if (is(T == double))
            return ulong2double(popInteger!(R, 8, false, endian)(input));
        else
            static assert(false, "Unsupported type " ~ T.stringof);
    }
}

unittest
{
    ubyte[] arr = [ 0x00, 0x01, 0x02, 0x03 ,
                    0x00, 0x01, 0x02, 0x03,
                    0x04, 0x05 ];

    assert(popLE!uint(arr) == 0x03020100);
    assert(popBE!int(arr) == 0x00010203);
    assert(popBE!ushort(arr) == 0x0405);
}


unittest
{
    ubyte[] arr = [0, 0, 0, 0, 0, 0, 0xe0, 0x3f];
    assert(popLE!double(arr) == 0.5);
    arr = [0, 0, 0, 0, 0, 0, 0xe0, 0xbf];
    assert(popLE!double(arr) == -0.5);
}
