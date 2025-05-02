TARGET = sqrt3
OBJS += sqrt3.o
OBJS += main.o

CC = mpicc
#CFLAGS = -Wall -Werror -DDEBUG -g # debug flags
CFLAGS = -std=gnu99 -Wall -Werror -g -O3 # release flags
CFLAGS += -MMD -MP
LDFLAGS += $(LIBS)

default:	$(TARGET)
all:		$(TARGET)

$(TARGET):	$(OBJS)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

DEPS = $(OBJS:%.o=%.d)
-include $(DEPS)

clean:
	rm $(TARGET) $(OBJS) $(DEPS) || true
