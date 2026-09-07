// A direct-transport Kitty client for native PTY smoke tests. The launcher must
// put its PTY into raw, no-echo mode before starting this executable.
package main

import (
	"bufio"
	"encoding/base64"
	"fmt"
	"os"
	"strings"
)

func main() {
	if len(os.Args) != 2 {
		panic("usage: kitty-client image.png")
	}
	data, err := os.ReadFile(os.Args[1])
	if err != nil {
		panic(err)
	}
	input := bufio.NewReader(os.Stdin)
	ack := func(id int) {
		response, err := input.ReadString('\\')
		expected := fmt.Sprintf("\x1b_Gi=%d;OK\x1b\\", id)
		if err != nil || response != expected {
			panic(fmt.Sprintf("expected %q, got %q (%v)", expected, response, err))
		}
	}
	fmt.Print("\x1b_Ga=q,t=d,f=24,s=1,v=1,i=100;/wAA\x1b\\")
	ack(100)
	fmt.Print("\x1b[2J\x1b[HKitty PNG transfer\r\n\x1b[3;3H")
	encoded := base64.StdEncoding.EncodeToString(data)
	for offset := 0; offset < len(encoded); {
		end := min(offset+4096, len(encoded))
		more := 0
		if end < len(encoded) {
			more = 1
		}
		header := fmt.Sprintf("m=%d", more)
		if offset == 0 {
			header = "a=T,t=d,f=100,i=101,c=32,r=12,C=1," + header
		}
		fmt.Printf("\x1b_G%s;%s\x1b\\", header, encoded[offset:end])
		offset = end
	}
	ack(101)
	fmt.Print("\x1b[17;1HPNG ACK received\x1b]2;Kitty displayed\x07")
	command, err := input.ReadByte()
	if err != nil || command != 'd' {
		panic("expected delete command")
	}
	fmt.Print("\x1b_Ga=d,d=I,i=101\x1b\\\x1b[17;1H" + strings.Repeat(" ", 24) + "\rImage deleted\x1b]2;Kitty deleted\x07")
	command, err = input.ReadByte()
	if err != nil || command != 'q' {
		panic("expected quit command")
	}
}
