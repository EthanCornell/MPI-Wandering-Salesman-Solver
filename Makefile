CC      = mpicc
CFLAGS  = -O3 -std=c11 -Wall -Wextra -march=native
LDFLAGS =

wsp-mpi: wsp-mpi.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f wsp-mpi
