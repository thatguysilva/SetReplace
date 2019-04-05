#ifndef Set_hpp
#define Set_hpp

#include <memory>
#include <vector>

#include "Expression.hpp"
#include "Rule.hpp"

namespace SetReplace {
    class Set {
    public:
        Set(const std::vector<Rule>& rules, const std::vector<Expression>& initialExpressions);
        
        int replace();
        int replace(const int stepCount);
        
        std::vector<Expression> expressions() const;
        
    private:
        class Implementation;
        std::shared_ptr<Implementation> implementation_;
    };
}

#endif /* Set_hpp */