#ifndef CALLING_CONTEXT_TREE_H
#define CALLING_CONTEXT_TREE_H

#include <map>
#include <deque>

class CallingContextTree {
 public:
  struct CCTNode {
    uint64_t func_addr;
    // block_offset->nblocks
    std::map<int, int> blocks;
    // callsite->node
    std::map<int, CCTNode> children;

    CCTNode() : func_addr(0) {}
    CCTNode(uint64_t func_addr) :
      func_addr(func_addr) {}
  };

  struct StackNode {
    uint64_t func_addr;
    int offset;

    StackNode() : func_addr(0), offset(0) {}
    StackNode(uint64_t func_addr, int offset) :
      func_addr(func_addr), offset(offset) {}
  };

  CallingContextTree() {}

  void call(int g_warp_id, uint64_t func_addr, int offset) {
    if (call_stacks_.find(g_warp_id) == call_stacks_.end()) {
      // gpu root
      StackNode stack_node;
      call_stacks_[g_warp_id].push_back(stack_node);
    }
    call_stacks_[g_warp_id].push_back(StackNode(func_addr, offset));
  }

  void ret(int g_warp_id) {
    call_stacks_[g_warp_id].pop_back();
  }

  void block(int g_warp_id, uint64_t func_addr, int offset) {
    update(call_stacks_[g_warp_id], func_addr, offset);
  }

  std::string to_string() {
  }
  
 private:
  // Copy a call_stack
  void update(std::deque<StackNode> call_stack,
    uint64_t func_addr, int offset) {
    auto &tree_node = root_;
    CCTNode *parent = NULL;
    int call_site = 0;
    while (call_stack.empty() == false) {
      auto &node = call_stack.front();
      call_stack.pop_front();
      if (tree_node.func_addr != node.func_addr) {
        CCTNode cct_node(node.func_addr);
        parent->children[call_site] = cct_node;
      }
      call_site = node.offset;
      parent = &tree_node;
      tree_node = tree_node.children[call_site];
    }
    // last node, update block
    tree_node.func_addr = func_addr;
    tree_node.blocks[offset]++;
  }

 private:
  std::map<int, std::deque<StackNode>> call_stacks_;
  CCTNode root_;
};

#endif
