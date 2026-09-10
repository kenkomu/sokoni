package account

import (
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
)

// ERC-20 calls the backend makes on a user's behalf. A transfer is always
// wrapped in EncodeExecute, so the token contract sees the account — not the
// bundler, not us — as msg.sender.

var (
	transferArgs  = abi.Arguments{{Type: mustType("address", nil)}, {Type: mustType("uint256", nil)}}
	balanceOfArgs = abi.Arguments{{Type: mustType("address", nil)}}
)

// EncodeERC20Transfer builds the inner call for moving a token.
func EncodeERC20Transfer(to common.Address, amount *big.Int) ([]byte, error) {
	if amount == nil || amount.Sign() <= 0 {
		return nil, fmt.Errorf("amount must be positive")
	}
	if amount.BitLen() > 256 {
		return nil, fmt.Errorf("amount exceeds uint256")
	}
	args, err := transferArgs.Pack(to, amount)
	if err != nil {
		return nil, err
	}
	return append(selector("transfer(address,uint256)"), args...), nil
}

// EncodeBalanceOf builds the eth_call for a token balance.
func EncodeBalanceOf(holder common.Address) ([]byte, error) {
	args, err := balanceOfArgs.Pack(holder)
	if err != nil {
		return nil, err
	}
	return append(selector("balanceOf(address)"), args...), nil
}
