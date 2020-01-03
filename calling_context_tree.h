#ifndef CALLING_CONTEXT_TREE_H
#define CALLING_CONTEXT_TREE_H

#include <map>
#include <set>
#include <deque>
#include <list>
#include <sstream>
#include <iostream>

#define CALLING_CONTEXT_TREE_DEBUG 0

class CallingContextTree {
 public:
  struct CCTNode {
    uint64_t func_addr;
    // block_offset->nblocks
    std::map<uint64_t, int> blocks;
    // callsite-><call_count, node>
    std::map<uint64_t, std::pair<CCTNode, int> > children;

    CCTNode() : func_addr(0) {}
    CCTNode(uint64_t func_addr) :
      func_addr(func_addr) {}
  };

  struct StackNode {
    uint64_t func_addr;
    uint64_t offset;

    StackNode() : func_addr(0), offset(0) {}
    StackNode(uint64_t func_addr, uint64_t offset) :
      func_addr(func_addr), offset(offset) {}
  };

  CallingContextTree() {}

  void call(int g_thread_id, uint64_t func_addr, uint64_t offset) {
    if (call_stacks_.find(g_thread_id) == call_stacks_.end()) {
      // gpu root
      StackNode stack_node(0, func_addr);
      call_stacks_[g_thread_id].push_back(stack_node);
    }
    call_stacks_[g_thread_id].push_back(StackNode(func_addr, offset));
    if (CALLING_CONTEXT_TREE_DEBUG) {
      std::cout << "thread: " << g_thread_id << " call " << std::hex << "0x" << offset <<
        " at func_addr 0x" << func_addr << std::dec << std::endl;
    }
    update(call_stacks_[g_thread_id], func_addr, offset, true, false);
  }

  void ret(int g_thread_id, uint64_t func_addr, uint64_t offset) {
    if (CALLING_CONTEXT_TREE_DEBUG) {
      std::cout << "thread: " << g_thread_id << " ret " << std::endl;
    }
    update(call_stacks_[g_thread_id], func_addr, offset, false, true);
    if (call_stacks_.find(g_thread_id) != call_stacks_.end()) {
      call_stacks_[g_thread_id].pop_back();
    }
  }

  void block(int g_thread_id, uint64_t func_addr, uint64_t offset) {
    update(call_stacks_[g_thread_id], func_addr, offset, false, false);
  }

  // map <function_addr> to <cubin_id, function_id>
  std::string dump(std::map<uint64_t, std::pair<int, int>> &func_cubin_map) {
    // [node_id, parent_id, cubin_id, offset, call_count]
    std::string ret;
    dfs2(root_, "", ret, func_cubin_map);
    return ret;
  }

  std::string to_string() {
    std::string ret;
    dfs1(root_, "", ret);
    return ret;
  }

  std::string dump_callees() {
    // <callsite, <block_maps, count>>
    std::map<uint64_t, std::vector<std::map<uint64_t, int>>> callees;
    dfs3(root_, callees); 

    std::string ret;
    for (auto iter : callees) {
      std::stringstream ss;
      auto func_addr = iter.first;
      ss << "0x" << std::hex << func_addr << std::dec << std::endl;

      auto &vec = iter.second;
      for (auto &b_map : vec) {
        for (auto b_iter : b_map) {
          ss << b_iter.first << ":" << b_iter.second << ",";
        }
        if (b_map.size() != 0) {
          ss << std::endl;
        }
      }
      ret += ss.str();
    }

    return ret;
  }
  
 private:
  // Copy a call_stack
  void update(std::list<StackNode> call_stack,
    uint64_t func_addr, uint64_t offset, bool is_call, bool is_ret) {
    CCTNode *tree_node = &root_;
    CCTNode *parent = NULL;
    uint64_t call_site = 0;
    while (call_stack.empty() == false) {
      auto node = call_stack.front();
      call_stack.pop_front();
      if (tree_node->func_addr != node.func_addr) {
        CCTNode cct_node(node.func_addr);
        parent->children[call_site].first = cct_node;
        tree_node = &(parent->children[call_site].first);
        if (CALLING_CONTEXT_TREE_DEBUG) {
          std::cout << "parent 0x" << std::hex << parent->func_addr <<
            " insert at 0x" << call_site << std::dec << std::endl;
        }
      }
      call_site = node.offset;
      parent = tree_node;
      tree_node = &(tree_node->children[call_site].first);
    }
    if (is_ret) {
      tree_node->func_addr = func_addr;
    } else if (is_call) {
      parent->children[call_site].second++;
    } else {
      // last node, update block
      tree_node->func_addr = func_addr;
      tree_node->blocks[offset]++;
    }
  }

  void dfs1(CCTNode &node, std::string prefix, std::string &ret) {
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
      dfs1(iter.second.first, prefix, ret);
    }
  }

  void dfs2(CCTNode &node, std::string prefix, std::string &ret,
    std::map<uint64_t, std::pair<int, int>> &func_cubin_map) {
    auto p = func_cubin_map[node.func_addr];
    for (auto iter : node.children) {
      // [module_id, function_id, offset]
      auto offset = iter.first;
      std::stringstream ss;
      ss << "[" << p.first << "," << p.second << "," <<
        std::hex << offset << "]->";
      std::stringstream sss;
      auto c_addr = iter.second.first.func_addr;
      p = func_cubin_map[c_addr];
      sss << prefix << ss.str() << "[" << p.first << "," << p.second <<
        ",0]->" << iter.second.second << std::endl;
      ret += sss.str();
      dfs2(iter.second.first, prefix + ss.str(), ret, func_cubin_map);
    }
  }

  void dfs3(CCTNode &node, std::map<uint64_t, std::vector<std::map<uint64_t,int>>> &callees) {
    for (auto iter : node.children) {
      auto *child = &(iter.second.first);
      auto offset = child->func_addr;
      callees[offset].push_back(child->blocks);
      dfs3(*child, callees);
    }
  }

 private:
  std::map<int, std::list<StackNode>> call_stacks_;
  CCTNode root_;
};

#endif
