SECTIONS
{
    .text : SUBALIGN(64)
    {
        *(.text .text.*)
    }
}
INSERT AFTER .rodata;
