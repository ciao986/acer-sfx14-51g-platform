obj-m += acer-sfx14-51g-platform.o

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

check:
	$(MAKE) -C $(KDIR) M=$(PWD) W=1 modules
