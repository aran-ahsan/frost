SRCS = $(shell find src -name *.bas)
SRCS += $(shell find src -name *.asm)
OBJS = $(addprefix obj/, $(addsuffix .o,$(basename $(notdir $(SRCS)))))
OBJS += obj/trampoline.o

COMPILER = fbc
ASSEMBLER = nasm
LINKER = ld

GIT_VERSION := $(shell git describe --dirty --always --tags)

CFLAGS = -c -nodeflibs -lang fb -arch 486 -i ./include/ -g -d FROST_DEBUG -d FROST_VERSION=\"$(GIT_VERSION)\"
AFLAGS = -f elf32
LFLAGS = -melf_i386 -Tkernel.ld

frost.krn: $(OBJS)
	$(LINKER) $(LFLAGS) -o $@ $^

obj/%.o: src/%.bas
	$(COMPILER) $(CFLAGS) $^ -o $@

obj/%.o: src/arch/x86/%.bas
	$(COMPILER) $(CFLAGS) $^ -o $@

obj/%.o: src/%.asm
	$(ASSEMBLER) $(AFLAGS) $^ -o $@

obj/%.o: src/arch/x86/%.asm
	$(ASSEMBLER) $(AFLAGS) $^ -o $@

obj/%.bin: src/arch/x86/%.asm.embedd
	$(ASSEMBLER) -f bin $^ -o $@

obj/%.o: obj/%.bin
	$(LINKER) -melf_i386 -r -b binary $^ -o $@

clean:
	rm -f $(OBJS) frost.krn

.PHONY: clean
