#ifndef CALLING_CONTEXT_TREE_H
#define CALLING_CONTEXT_TREE_H

#include <map>
#include <list>
#include <sstream>
#include <iostream>

#define CALLING_CONTEXT_TREE_DEBUG 0

class CallingContextTree {
 public:
  struct CCTNode {
    uint64_t func_addr;
    // block_offset->nblocks
    std::map<int, int> blocks;
    // callsite-><call_count, node>
    std::map<int, std::pair<CCTNode, int> > children;

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
      StackNode stack_node(0, func_addr);
      call_stacks_[g_warp_id].push_back(stack_node);
    }
    call_stacks_[g_warp_id].push_back(StackNode(func_addr, offset));
    update(call_stacks_[g_warp_id], func_addr, offset, true);
  }

  void ret(int g_warp_id) {
    call_stacks_[g_warp_id].pop_back();
  }

  void block(int g_warp_id, uint64_t func_addr, int offset) {
    update(call_stacks_[g_warp_id], func_addr, offset, false);
  }

  // map <function_addr, offset> to <cubin_id, offset>
  void dump(std::map<uint64_t, std::pair<int, uint64_t> > &function_cubin_map,
    const std::string &file_name) {
    // [node_id, parent_id, cubin_id, offset, call_count]
  }

  std::string to_string() {
    std::string ret;
    dfs(root_, "", ret);
    return ret;
  }
  
 private:
  // Copy a call_stack
  void update(std::list<StackNode> call_stack,
    uint64_t func_addr, int offset, bool is_call) {
    CCTNode *tree_node = &root_;
    CCTNode *parent = NULL;
    int call_site = 0;
    while (call_stack.empty() == false) {
      auto &node = call_stack.front();
      call_stack.pop_front();
      if (tree_node->func_addr != node.func_addr) {
        CCTNode cct_node(node.func_addr);
        parent->children[call_site].first = cct_node;
        tree_node = &(parent->children[call_site].first);
        if (CALLING_CONTEXT_TREE_DEBUG) {
          std::cout << "parent 0x" << parent->func_addr << " insert at 0x" << call_site << std::endl;
        }
      }
      call_site = node.offset;
      parent = tree_node;
      tree_node = &(tree_node->children[call_site].first);
    }
    if (is_call) {
      parent->children[call_site].second++;
    } else {
      // last node, update block
      tree_node->func_addr = func_addr;
      tree_node->blocks[offset]++;
    }
  }

  void dfs(CCTNode &node, std::string prefix, std::string &ret) {
    std::stringstream ss;
    ss << "Func: 0x" << std::hex << node.func_addr << std::endl;
    ret += ss.str();
    prefix += "    ";
    for (auto iter : node.blocks) {
      std::stringstream sss;
      sss << prefix << "BB: 0x" << std::hex << iter.first << ": " <<
        std::dec << iter.second << std::endl;
      ret += sss.str(); 
    }
    for (auto iter : node.children) {
      std::stringstream sss;
      sss << prefix << "Call: 0x" << std::hex << iter.first << ": " <<
        std::dec << iter.second.second << "->";
      ret += sss.str(); 
      dfs(iter.second.first, prefix, ret);
    }
  }

 private:
  std::map<int, std::list<StackNode>> call_stacks_;
  CCTNode root_;
};

#endif
