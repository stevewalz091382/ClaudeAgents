using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace CutOnce.Core;

/// <summary>A LISP symbol other than T and nil (for example setq or *cutonce:config*).</summary>
public sealed class LispSymbol
{
    public LispSymbol(string name) { Name = name; }
    public string Name { get; }
    public bool Is(string name) => string.Equals(Name, name, StringComparison.OrdinalIgnoreCase);
    public override string ToString() => Name;
}

/// <summary>
/// A LISP list. A dotted pair whose cdr is an atom, such as ("BrandColor" . 150),
/// keeps the atom in <see cref="Tail"/>. A dotted pair whose cdr is a list,
/// such as ("LockedSettings" . ("A" "B")), is the same list as ("LockedSettings" "A" "B").
/// </summary>
public sealed class LispList
{
    public LispList(List<object> items, object tail = null) { Items = items; Tail = tail; }
    public List<object> Items { get; }
    public object Tail { get; }

    public object Car => Items.Count > 0 ? Items[0] : null;

    /// <summary>The cdr: the atom after the dot, or the rest of the list (nil when empty).</summary>
    public object Cdr
    {
        get
        {
            if (Tail != null && Items.Count == 1) return Tail;
            if (Items.Count <= 1) return null;
            return new LispList(Items.GetRange(1, Items.Count - 1), Tail);
        }
    }
}

public sealed class LispReadException : Exception
{
    public LispReadException(string message, int line) : base($"Line {line}: {message}") { Line = line; }
    public int Line { get; }
}

/// <summary>
/// Reads AutoLISP data (not code) so CutOnce-Config.lsp keeps working unchanged:
/// lists, dotted pairs, quote, strings, integers, reals, T, nil and comments
/// (; to the end of the line, and ;| block |;). Nothing is evaluated.
/// T reads as true, nil and () as null, other symbols as <see cref="LispSymbol"/>.
/// </summary>
public static class LispReader
{
    public static List<object> ReadAll(string text)
    {
        var r = new Reader(text ?? "");
        var all = new List<object>();
        while (r.SkipBlank()) all.Add(r.ReadDatum());
        return all;
    }

    private sealed class Reader
    {
        private readonly string _s;
        private int _i;
        private int _line = 1;

        public Reader(string s) { _s = s; }

        private bool AtEnd => _i >= _s.Length;
        private char Peek => _s[_i];

        private char Next()
        {
            char c = _s[_i++];
            if (c == '\n') _line++;
            return c;
        }

        /// <summary>Skips whitespace and comments; false at the end of the text.</summary>
        public bool SkipBlank()
        {
            while (!AtEnd)
            {
                char c = Peek;
                if (char.IsWhiteSpace(c)) { Next(); continue; }
                if (c == ';')
                {
                    if (_i + 1 < _s.Length && _s[_i + 1] == '|')
                    {
                        int end = _s.IndexOf("|;", _i + 2, StringComparison.Ordinal);
                        int stop = end < 0 ? _s.Length : end + 2;
                        while (_i < stop) Next();
                    }
                    else
                    {
                        while (!AtEnd && Peek != '\n') Next();
                    }
                    continue;
                }
                return true;
            }
            return false;
        }

        public object ReadDatum()
        {
            if (!SkipBlank()) throw new LispReadException("Unexpected end of file.", _line);
            char c = Peek;
            switch (c)
            {
                case '(':
                    Next();
                    return ReadListBody();
                case ')':
                    throw new LispReadException("Unexpected ')'.", _line);
                case '\'':
                    Next();
                    return new LispList(new List<object> { new LispSymbol("quote"), ReadDatum() });
                case '"':
                    Next();
                    return ReadString();
                default:
                    return ReadAtom();
            }
        }

        private object ReadListBody()
        {
            var items = new List<object>();
            object tail = null;
            while (true)
            {
                if (!SkipBlank()) throw new LispReadException("Missing ')'.", _line);
                if (Peek == ')') { Next(); break; }
                if (Peek == '.' && IsDelimiterAt(_i + 1))
                {
                    Next();
                    object rest = ReadDatum();
                    if (rest is LispList restList)
                    {
                        items.AddRange(restList.Items);
                        tail = restList.Tail;
                    }
                    else if (rest != null)
                    {
                        tail = rest;
                    }
                    if (!SkipBlank() || Peek != ')') throw new LispReadException("Expected ')' after a dotted pair.", _line);
                    Next();
                    break;
                }
                items.Add(ReadDatum());
            }
            if (items.Count == 0 && tail == null) return null;
            return new LispList(items, tail);
        }

        private bool IsDelimiterAt(int i)
        {
            if (i >= _s.Length) return true;
            char c = _s[i];
            return char.IsWhiteSpace(c) || c == '(' || c == ')' || c == '"' || c == ';' || c == '\'';
        }

        private string ReadString()
        {
            var sb = new StringBuilder();
            while (true)
            {
                if (AtEnd) throw new LispReadException("Missing closing quote.", _line);
                char c = Next();
                if (c == '"') break;
                if (c == '\\')
                {
                    if (AtEnd) throw new LispReadException("Missing closing quote.", _line);
                    char e = Next();
                    switch (e)
                    {
                        case 'n': sb.Append('\n'); break;
                        case 't': sb.Append('\t'); break;
                        case 'r': sb.Append('\r'); break;
                        case 'e': sb.Append('\u001b'); break;
                        default: sb.Append(e); break;
                    }
                    continue;
                }
                sb.Append(c);
            }
            return sb.ToString();
        }

        private object ReadAtom()
        {
            int start = _i;
            while (!AtEnd && !IsDelimiterAt(_i)) Next();
            string tok = _s.Substring(start, _i - start);
            if (tok.Length == 0) throw new LispReadException($"Unexpected '{Peek}'.", _line);
            if (string.Equals(tok, "nil", StringComparison.OrdinalIgnoreCase)) return null;
            if (string.Equals(tok, "T", StringComparison.OrdinalIgnoreCase)) return true;
            if (long.TryParse(tok, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out long n)) return n;
            if (double.TryParse(tok, NumberStyles.Float, CultureInfo.InvariantCulture, out double d)) return d;
            return new LispSymbol(tok);
        }
    }
}
