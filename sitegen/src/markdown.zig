const cmark = @cImport({
    @cInclude("cmark-gfm.h");
});

pub const Markdown = struct {
    pub fn toHtml(markdown: []const u8) ?[*:0]u8 {
        return cmark.cmark_markdown_to_html(
            markdown.ptr,
            markdown.len,
            cmark.CMARK_OPT_DEFAULT,
        );
    }
};
